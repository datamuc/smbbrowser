#
# Author::    Danijel Tasov (mailto:dt@korn.shell.la)
# Copyright:: Copyright (c) 2011 Danijel Tasov
# License::   Beerware
#

module CIFS
    require 'java'
    require 'uri'
    require 'mime/types'
    require 'time'
    require 'rack/utils'
    include_package 'jcifs.smb'
    include_package 'jcifs.util'

    # FIXME
    #
    # Seems jetty and webrick behave differently here :(
    def CIFS::escape_uri(uri)
        uri = URI.escape(uri, /[^A-Za-z0-9\/]/)
        uri.gsub(/%2B/, '%252B')
    end

    module File
        # Creates a jcifs.smb.SmbFile object
        #
        # file:: required, has to be an smb url
        #        See http://jcifs.samba.org/src/docs/api/jcifs/smb/SmbFile.html
        #
        # +domain+:: optional
        # +user+:: optional
        # +pass+:: optional
        #
        # If +pass+ is not specified the CIFS server is accessed anonymously
        # and +user+ and +domain+ is ignored
        def File::get(file, domain=nil, user=nil, pass=nil)
            if pass and !pass.empty?
                auth = CIFS::NtlmPasswordAuthentication.new(domain, user, pass)
                smbfile = CIFS::SmbFile.new(file, auth)
            else
                smbfile = CIFS::SmbFile.new(file)
            end
            return smbfile
        end

        # returns a simple string indicating the type of a file
        # +file+:: is a SmbFile object
        #
        # returns:: one of dir, file, printer, share, workgroup, pipe,
        #           comm, server, unknown
        #
        # It is used to select the right icon in the directory browser
        def File::get_icon(file)
            case file.getType
                when CIFS::SmbFile::TYPE_FILESYSTEM
                    file.isDirectory ? "dir" : "file"
                when CIFS::SmbFile::TYPE_PRINTER
                    "printer"
                when CIFS::SmbFile::TYPE_SHARE
                    "share"
                when CIFS::SmbFile::TYPE_WORKGROUP
                    "workgroup"
                when CIFS::SmbFile::TYPE_NAMED_PIPE
                    "pipe"
                when CIFS::SmbFile::TYPE_COMM
                    "comm"
                when CIFS::SmbFile::TYPE_SERVER
                    "server"
                else
                    "unknown"
            end
        end

    end

    # This class reads SmbFiles
    class FileReader
        def initialize(smbfile)
            @smbfile = smbfile
            @bytes = Java::byte[128 * 1024].new
            self.create_input
        end

        def create_input
            @input = CIFS::SmbFileInputStream.new(@smbfile)
        end

        # returns the mime type of the SmbFile based on it's file name
        def mime_type
            name = @smbfile.getName
            mime = MIME::Types.type_for(name)[0]

            if ['text/plain'].find_index(mime)
                return mime.to_s + "; charset=utf-8"
            end

            return mime.to_s if mime
            return 'text/plain; charset=UTF-8'
        end

        def response
            header = Rack::Utils::HeaderHash.new()
            header['Last-Modified']       = Time.at(@smbfile.getLastModified / 1000).httpdate,
            header['Content-Length']      = @smbfile.length.to_s,
            header['Content-Type']        = self.mime_type.to_s,
            header['Content-Disposition'] = 'filename*="%s"' % \
                URI.escape(@smbfile.getName, /[^A-Za-z0-9\/]/)
            [200, header, self]
        end

        # This yields chunks of the body, rack calls this to generate the
        # request body
        def each # :yields: bodychunk
            while ( read = @input.read(@bytes) ) > 0
                yield String.from_java_bytes(@bytes[Range.new(0, read-1)])
            end
        end

        protected :create_input
    end

    # We throw this exception when we cannot satisfy the range
    class RangeNotSatisfiableException < Exception; end

    # The RangeFileReader is a child of the FileReader and supports
    # receiving of partial contents of a SmbFile
    class RangeFileReader < FileReader
        # +smbfile+:: an SmbFile
        # +range+:: the value of an HTTP range header, e. g. 'bytes=-5000'
        #
        # Currently only one byte-range-spec is supported, i. e. 'bytes=5-10'
        # but *NOT* 'bytes=5-10,-5,70-'. See RFC 2616 14.35.1 for details
        def initialize(smbfile, range)
            super(smbfile)
            self.create_input

            @boundary = nil
            @length = @smbfile.getContentLength
            @range = parse_range(range)
            @multipart = @range.length > 1

            if @multipart
                raise RangeNotSatisfiableException,
                    "multipart/byteranges not supported yet"
            end

            @header = {
                'Content-Disposition' => 'filename*="%s"' % \
                    URI.escape(@smbfile.getName, /[^A-Za-z0-9\/]/),
                'Last-Modified' => Time.at(@smbfile.getLastModified / 1000).httpdate,
            }

            if @multipart
                @header['Content-Type'] = 'multipart/byteranges; boundary=' + self.boundary
            else
                r = @range[0].content_range
                @header['Content-Range'] = r
                @header['Content-Type']  = self.mime_type.to_s
            end

            @header = Rack::Utils::HeaderHash.new(@header)
        end

        def create_input
            @input = CIFS::SmbRandomAccessFile.new(@smbfile, 'r')
        end

        # a boundary for multipart/byterange responses
        # currently unused, since multipart/byteranges are currently
        # no supported, maybe this should be private too
        def boundary
            if ! @boundary
                @boundary = 'laskdfjalskdfjaslkdj' # FIXME
            end
            @boundary
        end

        def parse_range(range_header)
            range_header.strip!
            if ! range_header.start_with?("bytes=")
                raise RangeNotSatisfiableException, "only bytes ranges supported"
            end
            range_header.sub!('bytes=', '')
            raise RangeNotSatisfiableException, "invalid range" if range_header.empty?

            specs = range_header.split(',').map { |s| s.strip }

            # check specs
            specs.each do |s|
                next if s.match(/^\d+-\d+$/)
                next if s.match(/^-\d+$/) and !s.match(/^-0+$/)
                next if s.match(/^\d+-$/)
                raise RangeNotSatisfiableException, "#{s} is not a valid range spec"
            end

            specs = specs.map { |s| RangeHelper.new(s, @length) }
            return specs
        end

        # returns a rack response
        def response
            [216, @header, self]
        end

        # returns a rack body
        def each # :yields: bodychunk
            type   = self.mime_type

            @range.each do |r|
                if @multipart
                    yield "\n--#{ self.boundary }"
                    yield "\nContent-Type: %s" % type
                    yield "\nContent-Range: %s" % r.content_range
                    yield "\n\n"
                end

                @input.seek(r.first)
                toread = r.to_read
                while toread > 0
                    buflen = toread < @bytes.length ? toread : @bytes.length
                    #puts("%d %d %d" % [buflen, toread, @input.getFilePointer])
                    @input.read(@bytes, 0, buflen)
                    yield String.from_java_bytes(@bytes[0..buflen-1])
                    toread -= buflen
                end
            end
        end

        protected :create_input
        private :parse_range
    end

    class RangeHelper
        attr_reader :first, :last

        # spec:: 'x-y', 'x-' or '-y', see RFC 2616 14.35.1
        # length:: the Content-Length
        def initialize(spec, length)
            @spec = spec
            @vals = spec.split('-').map{ |x| x.empty? ? nil : x.to_i }
            @length = length
            @first = create_first
            @last  = create_last
            if @first > @last
                raise RangeNotSatisfiableException, \
                    "invalid spec #{ @spec } first #{@first} last #{@last} length #{@length}"
            end
        end

        def create_first
            if @vals[1] and not @vals[0]
                r = @length - @vals[1]
                return r < 0 ? 0 : r
            else
                if @vals[0] and @vals[1]
                    return @vals[0]
                else
                    return @vals[0]
                end
            end
        end
        
        def create_last
            last = @length - 1

            if @vals[0] and @vals[1]
                return last < @vals[1] ? last : @vals[1]
            else
                return last
            end

        end

        # returns the value for the HTTP Content-Range header
        def content_range
            "%d-%d/%d" % [self.first, self.last, @length]
        end

        # how much bytes must be read for this range
        def to_read
            @last - @first + 1
        end

        private :create_first, :create_last
    end

    class DirReader
        # +smbfile+:: a jcifs.smb.SmbFile object
        def initialize(smbfile)
            @smbfile = smbfile
            @files = @smbfile.listFiles
        end

        # yields a sorted list of SmbFile objects
        def each
            @files \
                .sort{ |a,b| a.getName <=> b.getName } \
                .each{ |file| yield file }
        end
    end
end
