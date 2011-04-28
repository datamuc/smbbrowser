module CIFS
    require 'java'
    require 'mime/types'
    include_package 'jcifs.smb'
    include_package 'jcifs.util'

    module File
        def File::get(file, domain=nil, user=nil, pass=nil)
            if pass and !pass.empty?
                auth = CIFS::NtlmPasswordAuthentication.new(domain, user, pass)
                smbfile = CIFS::SmbFile.new(file, auth)
            else
                smbfile = CIFS::SmbFile.new(file)
            end
            return smbfile
        end

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

    class FileReader
        def initialize(smbfile)
            @smbfile = smbfile
            @input = CIFS::SmbFileInputStream.new(@smbfile)
            @bytes = Java::byte[4096].new
        end

        def mime_type
            name = @smbfile.getName
            mime = MIME::Types.type_for(name)[0]

            if ['text/plain'].find_index(mime)
                return mime.to_s + "; charset=utf-8"
            end

            return mime.to_s if mime
            return 'application/octet-stream'
        end

        def each
            while ( read = @input.read(@bytes) ) > 0
                yield String.from_java_bytes(@bytes[Range.new(0, read-1)])
            end
        end
    end

    class DirReader
        def initialize(smbfile)
            @smbfile = smbfile
            @files = @smbfile.listFiles
        end

        def each
            @files \
                .sort{ |a,b| a.getName <=> b.getName } \
                .each{ |file| yield file }
        end
    end
end
