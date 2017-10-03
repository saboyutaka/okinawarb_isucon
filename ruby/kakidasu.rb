require 'mysql2'
require 'fileutils'

def config
  @config ||= {
    db: {
      host: ENV['ISUCONP_DB_HOST'] || 'localhost',
      port: ENV['ISUCONP_DB_PORT'] && ENV['ISUCONP_DB_PORT'].to_i,
      username: ENV['ISUCONP_DB_USER'] || 'root',
      password: ENV['ISUCONP_DB_PASSWORD'],
      database: ENV['ISUCONP_DB_NAME'] || 'isuconp',
    },
  }
end

def db
  return Thread.current[:isuconp_db] if Thread.current[:isuconp_db]
  client = Mysql2::Client.new(
    host: config[:db][:host],
    port: config[:db][:port],
    username: config[:db][:username],
    password: config[:db][:password],
    database: config[:db][:database],
    encoding: 'utf8mb4',
    reconnect: true,
  )
  client.query_options.merge!(symbolize_keys: true, database_timezone: :local, application_timezone: :local)
  Thread.current[:isuconp_db] = client
  client
end


public_path = File.expand_path('../public/image')
FileUtils.mkdir_p(public_path)
image_ids = db.prepare('SELECT id FROM `posts`').execute().map {|p| p[:id] }
image_ids.each do |id|
  img = db.prepare('SELECT * FROM `posts` WHERE `id` = ?').execute(id).first
  ext = img[:mime].split("/").last
  path = File.join(public_path, id.to_s + '.' + ext)
  File.write(path, img[:imgdata])
  if ext == 'jpeg'
    path = File.join(public_path, id.to_s + '.jpg')
    File.write(path, img[:imgdata])
  end
end
