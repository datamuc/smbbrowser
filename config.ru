# vim: ft=ruby
$:.unshift File.join(File.dirname(__FILE__), 'lib')
require 'rubygems'
require 'smb'
run Sinatra::Application
