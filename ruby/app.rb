require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack-flash'
require 'shellwords'
require 'rack-lineprof'
require 'rack-mini-profiler'
require 'flamegraph'
require 'stackprof'
require 'pry'
require 'json'

module Isuconp
  class App < Sinatra::Base
    use Rack::Session::Memcache, autofix_keys: true, secret: ENV['ISUCONP_SESSION_SECRET'] || 'sendagaya'
    use Rack::Flash
    set :public_folder, File.expand_path('../../public', __FILE__)

    use Rack::Lineprof if ENV['DEBUG']
    use Rack::MiniProfiler if ENV['DEBUG']

    UPLOAD_LIMIT = 10 * 1024 * 1024 # 10mb

    POSTS_PER_PAGE = 20

    helpers do
      def config
        @config ||= {
          db: {
            host:     ENV['ISUCONP_DB_HOST'] || 'localhost',
            port:     ENV['ISUCONP_DB_PORT'] && ENV['ISUCONP_DB_PORT'].to_i,
            username: ENV['ISUCONP_DB_USER'] || 'root',
            password: ENV['ISUCONP_DB_PASSWORD'],
            database: ENV['ISUCONP_DB_NAME'] || 'isuconp',
          },
        }
      end

      def db
        return Thread.current[:isuconp_db] if Thread.current[:isuconp_db]
        client = Mysql2::Client.new(
          host:      config[:db][:host],
          port:      config[:db][:port],
          username:  config[:db][:username],
          password:  config[:db][:password],
          database:  config[:db][:database],
          encoding:  'utf8mb4',
          reconnect: true,
        )
        client.query_options.merge!(symbolize_keys: true, database_timezone: :local, application_timezone: :local)
        Thread.current[:isuconp_db] = client
        client
      end

      def db_initialize
        sql = []
        sql << 'DELETE FROM users WHERE id > 1000'
        sql << 'DELETE FROM posts WHERE id > 10000'
        sql << 'DELETE FROM comments WHERE id > 100000'
        sql << 'UPDATE users SET del_flg = 0'
        sql << 'UPDATE users SET del_flg = 1 WHERE id % 50 = 0'
        sql.each do |s|
          db.xquery(s)
        end
        Dir['../public/image/*'].select {|path| path.scan(/\d+/)[0].to_i > 10000}.each {|path| FileUtils.rm(path)}
      end

      def try_login(account_name, password)
        user = db.xquery('SELECT * FROM users WHERE account_name = ? AND del_flg = 0', account_name).first

        if user && calculate_passhash(user[:account_name], password) == user[:passhash]
          return user
        elsif user
          return nil
        else
          return nil
        end
      end

      def validate_user(account_name, password)
        if !(/\A[0-9a-zA-Z_]{3,}\z/ =~ account_name && /\A[0-9a-zA-Z_]{6,}\z/ =~ password)
          return false
        end

        return true
      end

      def digest(src)
        # opensslのバージョンによっては (stdin)= というのがつくので取る
        `printf "%s" #{Shellwords.shellescape(src)} | openssl dgst -sha512 | sed 's/^.*= //'`.strip
      end

      def calculate_salt(account_name)
        digest account_name
      end

      def calculate_passhash(account_name, password)
        digest "#{password}:#{calculate_salt(account_name)}"
      end

      def get_session_user()
        if session[:user]
          db.xquery('SELECT * FROM `users` WHERE `id` = ?', session[:user][:id]).first
        else
          nil
        end
      end

      def update_post_cache post
        post[:body] = JSON.parse(post[:body])['body'] rescue post[:body]
        count = post[:comment_count] = db.xquery('SELECT COUNT(*) AS `count` FROM `comments` WHERE `post_id` = ?', post[:id]).first[:count]
        comment_ids = db.xquery('SELECT post_id, id FROM `comments` WHERE `post_id` = ? ORDER BY `created_at` DESC LIMIT 3', post[:id]).map { |comment| comment[:id] }
        body = { body: post[:body], comment_count: count, first_three: comment_ids }.to_json
        db.xquery('UPDATE `posts` set body = ? where id = ?', body, post[:id])
        post[:comment_count] = count
        post[:first_three] = comment_ids
      end

      def convert_post post
        foo = JSON.parse post[:body]
        post[:body] = foo['body']
        post[:comment_count] = foo['comment_count']
        post[:first_three] = foo['first_three']
      rescue
        update_post_cache post
      end

      def make_posts(results, all_comments: false)
        posts = results.map { |p| convert_post p; p }
        if all_comments
          post_ids = posts.map { |p| p[:id] }
          if post_ids.empty?
            comments = []
          else
            comments = db.xquery('SELECT * FROM `comments` WHERE `post_id` in ('+post_ids.join(',')+') ORDER BY `created_at` DESC').to_a
          end
        else
          comment_ids = posts.map { |p| p[:first_three] }.flatten
          if comment_ids.empty?
            comments = []
          else
            comments = db.xquery('SELECT * FROM `comments` WHERE `id` in ('+comment_ids.join(',')+') ORDER BY `created_at` DESC').to_a
          end
        end
        user_ids = comments.map { |c| c[:user_id] }.uniq | posts.map { |p| p[:user_id] }
        
        users = db.xquery('SELECT * from users where id in ('+user_ids.join(',')+')').to_a
        user_by_id = users.group_by { |u| u[:id] }.map { |id, us| [id, us.first] }.to_h

        comments.each do |c|
          c[:user] = user_by_id[c[:user_id]]
          raise unless c[:user]
        end
        comments_by_post_id = comments.group_by { |c| c[:post_id] }

        posts.to_a.each do |post|
          post[:comments] = comments_by_post_id[post[:id]] || []
          post[:user] = user_by_id[post[:user_id]]
          raise unless post[:user]
        end

        posts
      end

      def image_url(post)
        ext = ""
        if post[:mime] == "image/jpeg"
          ext = ".jpg"
        elsif post[:mime] == "image/png"
          ext = ".png"
        elsif post[:mime] == "image/gif"
          ext = ".gif"
        end

        "/image/#{post[:id]}#{ext}"
      end
    end

    get '/initialize' do
      db_initialize
      return 200
    end

    get '/login' do
      if get_session_user()
        redirect '/', 302
      end
      erb :login, layout: :layout, locals: { me: nil }
    end

    post '/login' do
      if get_session_user()
        redirect '/', 302
      end

      user = try_login(params['account_name'], params['password'])
      if user
        session[:user]       = {
          id: user[:id]
        }
        session[:csrf_token] = SecureRandom.hex(16)
        redirect '/', 302
      else
        flash[:notice] = 'アカウント名かパスワードが間違っています'
        redirect '/login', 302
      end
    end

    get '/register' do
      if get_session_user()
        redirect '/', 302
      end
      erb :register, layout: :layout, locals: { me: nil }
    end

    post '/register' do
      if get_session_user()
        redirect '/', 302
      end

      account_name = params['account_name']
      password     = params['password']

      validated = validate_user(account_name, password)
      if !validated
        flash[:notice] = 'アカウント名は3文字以上、パスワードは6文字以上である必要があります'
        redirect '/register', 302
        return
      end

      user = db.xquery('SELECT 1 FROM users WHERE `account_name` = ?', account_name).first
      if user
        flash[:notice] = 'アカウント名がすでに使われています'
        redirect '/register', 302
        return
      end

      query = 'INSERT INTO `users` (`account_name`, `passhash`) VALUES (?,?)'
      db.xquery(query, account_name, calculate_passhash(account_name, password))

      session[:user]       = {
        id: db.last_id
      }
      session[:csrf_token] = SecureRandom.hex(16)
      redirect '/', 302
    end

    get '/logout' do
      session.delete(:user)
      redirect '/', 302
    end

    get '/' do
      me = get_session_user()
      results = db.xquery('SELECT `posts`.`id`, `user_id`, `body`, `posts`.`created_at`, `mime` FROM `posts` inner join users on users.id = posts.user_id where users.del_flg = 0 ORDER BY `posts`.`created_at` DESC limit '+POSTS_PER_PAGE.to_s)
      posts = make_posts(results)

      erb :index, layout: :layout, locals: { posts: posts, me: me }
    end

    get '/@:account_name' do
      user = db.xquery('SELECT * FROM `users` WHERE `account_name` = ? AND `del_flg` = 0', params[:account_name]).first

      if user.nil?
        return 404
      end

      results = db.xquery('SELECT `id`, `user_id`, `body`, `mime`, `created_at` FROM `posts` WHERE `user_id` = ? ORDER BY `created_at` DESC', user[:id])
      posts   = make_posts(results)

      comment_count = db.xquery('SELECT COUNT(*) AS count FROM `comments` WHERE `user_id` = ?', user[:id]).first[:count]

      post_ids   = db.xquery('SELECT `id` FROM `posts` WHERE `user_id` = ?', user[:id]).map {|post| post[:id]}
      post_count = post_ids.length

      commented_count = 0
      if post_count > 0
        placeholder     = (['?'] * post_ids.length).join(",")
        commented_count = db.xquery("SELECT COUNT(*) AS count FROM `comments` WHERE `post_id` IN (#{placeholder})", *post_ids).first[:count]
      end

      me = get_session_user()

      erb :user, layout: :layout, locals: { posts: posts, user: user, post_count: post_count, comment_count: comment_count, commented_count: commented_count, me: me }
    end

    get '/posts' do
      max_created_at = params['max_created_at']
      results        = db.xquery(
        %(
          SELECT `posts`.`id`, `user_id`, `body`, `mime`, `posts`.`created_at` FROM `posts`
          inner join users on users.id = posts.user_id where users.del_flg = 0
          and `posts`.`created_at` <= ? ORDER BY `posts`.`created_at` DESC LIMIT #{POSTS_PER_PAGE}
        ),
        max_created_at.nil? ? nil : Time.iso8601(max_created_at).localtime
      )
      posts          = make_posts(results)

      erb :posts, layout: false, locals: { posts: posts }
    end

    get '/posts/:id' do
      results = db.xquery('SELECT * FROM `posts` WHERE `id` = ?', params[:id])
      posts   = make_posts(results, all_comments: true)

      return 404 if posts.length == 0

      post = posts[0]

      me = get_session_user()

      erb :post, layout: :layout, locals: { post: post, me: me }
    end

    post '/' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if params['csrf_token'] != session[:csrf_token]
        return 422
      end

      if params['file']
        mime = ''
        # 投稿のContent-Typeからファイルのタイプを決定する
        if params["file"][:type].include? "jpeg"
          mime = "image/jpeg"
        elsif params["file"][:type].include? "png"
          mime = "image/png"
        elsif params["file"][:type].include? "gif"
          mime = "image/gif"
        else
          flash[:notice] = '投稿できる画像形式はjpgとpngとgifだけです'
          redirect '/', 302
        end

        if params['file'][:tempfile].read.length > UPLOAD_LIMIT
          flash[:notice] = 'ファイルサイズが大きすぎます'
          redirect '/', 302
        end

        params['file'][:tempfile].rewind
        query = 'INSERT INTO `posts` (`user_id`, `mime`, `imgdata`, `body`) VALUES (?,?,?,?)'
        db.xquery(query, me[:id], mime, '', params["body"])
        pid = db.last_id
        img = params["file"][:tempfile].read

        public_path = File.expand_path('../public/image', __dir__)
        ext = mime.split('/').last
        File.write(File.join(public_path, pid.to_s + "." + ext), img)
        File.write(File.join(public_path, pid.to_s + ".jpg"), img) if ext == "jpeg"

        redirect "/posts/#{pid}", 302
      else
        flash[:notice] = '画像が必須です'
        redirect '/', 302
      end
    end

    get '/image/:id.:ext' do
      if params[:id].to_i == 0
        return ""
      end

      post = db.xquery('SELECT * FROM `posts` WHERE `id` = ?', params[:id].to_i).first

      if (params[:ext] == "jpg" && post[:mime] == "image/jpeg") ||
        (params[:ext] == "png" && post[:mime] == "image/png") ||
        (params[:ext] == "gif" && post[:mime] == "image/gif")
        headers['Content-Type'] = post[:mime]
        return post[:imgdata]
      end

      return 404
    end

    post '/comment' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if params["csrf_token"] != session[:csrf_token]
        return 422
      end

      unless /\A[0-9]+\z/ =~ params['post_id']
        return 'post_idは整数のみです'
      end
      post_id = params['post_id']

      query = 'INSERT INTO `comments` (`post_id`, `user_id`, `comment`) VALUES (?,?,?)'
      db.xquery(query, post_id, me[:id], params['comment'])

      post = db.xquery('SELECT `id`, `body` FROM `posts` where id = ?', params['post_id']).first
      update_post_cache post

      redirect "/posts/#{post_id}", 302
    end

    get '/admin/banned' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if me[:authority] == 0
        return 403
      end

      users = db.query('SELECT * FROM `users` WHERE `authority` = 0 AND `del_flg` = 0 ORDER BY `created_at` DESC')

      erb :banned, layout: :layout, locals: { users: users, me: me }
    end

    post '/admin/banned' do
      me = get_session_user()

      if me.nil?
        redirect '/', 302
      end

      if me[:authority] == 0
        return 403
      end

      if params['csrf_token'] != session[:csrf_token]
        return 422
      end

      query = 'UPDATE `users` SET `del_flg` = ? WHERE `id` = ?'

      params['uid'].each do |id|
        db.xquery(query, 1, id.to_i)
      end

      redirect '/admin/banned', 302
    end
  end
end
