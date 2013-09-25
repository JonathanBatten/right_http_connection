#
# Copyright (c) 2008 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#

# Net::HTTP and Net::HTTPGenericRequest fixes to support 100-continue on 
# POST and PUT. The request must have 'expect' field set to '100-continue'.


module Net
  
  class BufferedIO #:nodoc:
    # Monkey-patch Net::BufferedIO to read > 1024 bytes from the socket at a time

    # Default size (in bytes) of the max read from a socket into the user space read buffers for socket IO
    DEFAULT_SOCKET_READ_SIZE = 16*1024

    @@socket_read_size = DEFAULT_SOCKET_READ_SIZE

    def self.socket_read_size=(readsize)
      if(readsize <= 0)
        return
      end
      @@socket_read_size = readsize
    end

    def self.socket_read_size?()
      @@socket_read_size
    end

    def rbuf_fill
      timeout(@read_timeout) {
        @rbuf << @io.sysread(@@socket_read_size)
      }
    end
  end


  #-- Net::HTTPGenericRequest --

  class HTTPGenericRequest
    # Monkey-patch Net::HTTPGenericRequest to read > 1024 bytes from the local data
    # source at a time (used in streaming PUTs)

    # Default size (in bytes) of the max read from a local source (File, String,
    # etc.) to the user space write buffers for socket IO.
    DEFAULT_LOCAL_READ_SIZE = 16*1024

    @@local_read_size = DEFAULT_LOCAL_READ_SIZE

    def self.local_read_size=(readsize)
      if(readsize <= 0)
        return
      end
      @@local_read_size = readsize
    end

    def self.local_read_size?()
      @@local_read_size
    end

    def exec(sock, ver, path, send_only=nil)   #:nodoc: internal use only
      if @body
        send_request_with_body sock, ver, path, @body, send_only
      elsif @body_stream
        send_request_with_body_stream sock, ver, path, @body_stream, send_only
      else
        write_header(sock, ver, path)
      end
    end

    private

    def send_request_with_body(sock, ver, path, body, send_only=nil)
      self.content_length = body.respond_to?(:bytesize) ? body.bytesize : body.length
      delete 'Transfer-Encoding'
      supply_default_content_type
      write_header(sock, ver, path) unless send_only == :body
      sock.write(body && body.to_s) unless send_only == :header
    end

    def send_request_with_body_stream(sock, ver, path, f, send_only=nil)
      # KD: Fix 'content-length': it must not be greater than a piece of file left to be read.
      # Otherwise the connection may behave like crazy causing 4xx or 5xx responses
      #
      # Only do this helpful thing if the stream responds to :pos (it may be something
      # that responds to :read and :size but not :pos).
      if f.respond_to?(:pos)
        file_size           = f.respond_to?(:lstat) ? f.lstat.size : f.size
        bytes_to_read       = [ file_size - f.pos, self.content_length.to_i ].sort.first
        self.content_length = bytes_to_read
      end

      unless content_length() or chunked?
        raise ArgumentError,
            "Content-Length not given and Transfer-Encoding is not `chunked'"
      end
      bytes_to_read ||= content_length()
      supply_default_content_type
      write_header(sock, ver, path) unless send_only == :body
      unless send_only == :header
        if chunked?
          while s = f.read(@@local_read_size)
            sock.write(sprintf("%x\r\n", s.length) << s << "\r\n")
          end
          sock.write "0\r\n\r\n"
        else
          # KD: When we read/write over file EOF it sometimes make the connection unstable
          read_size = [ @@local_read_size, bytes_to_read ].sort.first
          while s = f.read(read_size)
            sock.write s
            # Make sure we do not read over EOF or more than expected content-length
            bytes_to_read -= read_size
            break if bytes_to_read <= 0
            read_size = bytes_to_read if bytes_to_read < read_size
          end
        end
      end
    end    
  end

end
