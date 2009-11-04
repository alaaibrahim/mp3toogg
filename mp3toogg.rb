#!/usr/bin/env ruby

require "tmpdir"
require "thread"
require "id3lib"

class Convertor
  @@mplayer = "/usr/bin/mplayer"
  @@oggenc = "/usr/bin/oggenc"
  @@ogg_dir = ENV["HOME"] + "/Music"

  def initialize(file)
    @original_file_name = file
    @original_file_size = File.stat(file).size
  end

  def get_id3
    tag = ID3Lib::Tag.new(@original_file_name)
    @id3_title = tag.title
    @id3_artist = tag.artist
    @id3_album = tag.album
    @id3_track = tag.track
    @id3_year = tag.year
    @id3_genre = ID3Lib::Info::Genres[tag.genre.sub('(','').sub(')','').to_i] unless tag.genre.nil?
  end

  def convert_to_pcm
    while(true) do
      @pcm_file = Dir.tmpdir + "/#{File.basename(@original_file_name)}-#{Time.now.strftime("%Y%m%d")}-#{$$}-#{rand(0x100000000).to_s(36)}"
      break unless File.exist?(@pcm_file)
    end
    command = "#{@@mplayer} -ao pcm:file=%#{@pcm_file.length}%\"#{@pcm_file}\" \"#{@original_file_name}\""
    `#{command}`
  end

  def convert_to_ogg
    @ogg_file_name = "#{@@ogg_dir}/#{@original_file_name.gsub(/\.mp3$/i,'.ogg')}"
    command = "#{@@oggenc} \"#{@pcm_file}\" -o \"#{@ogg_file_name}\""
    command += " -t \"#{@id3_title}\"" unless @id3_title.nil?
    command += " -a \"#{@id3_artist}\"" unless @id3_artist.nil?
    command += " -l \"#{@id3_album}\"" unless @id3_album.nil?
    command += " -N \"#{@id3_track}\"" unless @id3_track.nil?
    command += " -d \"#{@id3_year}\"" unless @id3_year.nil?
    command += " -G \"#{@id3_genre}\"" unless @id3_genre.nil?
    command += " 2>&1"
    `#{command}`
    @ogg_file_size = File.stat(@ogg_file_name).size
  end

  def clean_up
    File.unlink(@pcm_file)
    gained = @original_file_size - @ogg_file_size
    percent = (gained * 1.0 / @original_file_size) * 100
    "Converted \"#{@original_file_name}\" to \"#{@ogg_file_name}\" and gained #{gained} (#{"%.2f" % percent}%)"
  end

end

files_queue = Queue.new
ARGV.each do |file|
  begin
    convertor = Convertor.new(file)
    files_queue.enq(convertor)
  rescue
    puts $!
  end
end
files_queue.enq(:END_OF_WORK)

mplayer_queue = Queue.new
ogg_queue = Queue.new
cleanup_queue = Queue.new

threads = []

# get_id3 Thread
id3_thr = Thread.new do
  while (true) do
    obj = files_queue.deq
    if obj == :END_OF_WORK
      mplayer_queue.enq(:END_OF_WORK)
      break
    end
    obj.get_id3
    mplayer_queue.enq(obj)
    sleep 0.1
  end
end

# convert_to_pcm Thread
mplayer_thr =  Thread.new do
  while (true) do
    obj = mplayer_queue.deq
    break if obj == :END_OF_WORK
    obj.convert_to_pcm
    ogg_queue.enq(obj)
    while ogg_queue.length >= 20
      sleep 1
    end
  end
end

# convert_to_ogg Thread
ogg_thr = []
3.times do
  ogg_thr << Thread.new do
    while (true) do
      obj = ogg_queue.deq
      break if obj == :END_OF_WORK
      obj.convert_to_ogg
      cleanup_queue.enq(obj)
    end
  end
end

# cleanup Thread
cleanup_thr = Thread.new do
  log_file = File.open(ENV["HOME"] + "/mp32ogg.log", "a")
  while (true) do
    obj = cleanup_queue.deq
    break if obj == :END_OF_WORK
    log_file.puts obj.clean_up
  end
  log_file.close
end

# watcher
watcher_thr = Thread.new do
  while true
    puts "#{files_queue.length}\t#{mplayer_queue.length}\t#{ogg_queue.length}\t#{cleanup_queue.length}"
    sleep 1
  end
end
id3_thr.join
mplayer_thr.join
ogg_thr.length.times {ogg_queue.enq(:END_OF_WORK)}
ogg_thr.each {|thr| thr.join}
cleanup_queue.enq(:END_OF_WORK)
cleanup_thr.join
watcher_thr.kill
puts "Done"
