require "sinatra"
require 'koala'
require 'logger'
require 'neography'
require 'builder'

enable :sessions
set :raise_errors, false
set :show_exceptions, false

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = 'user_likes,user_photos,user_photo_video_tags'

log = Logger.new('./logger.log')
log.level = Logger::DEBUG

unless ENV["FACEBOOK_APP_ID"] && ENV["FACEBOOK_SECRET"]
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end

before do
  # HTTPS redirect
  if settings.environment == :production && request.scheme != 'https'
    redirect "https://#{request.env['HTTP_HOST']}"
  end
end

helpers do
  def host
    request.env['HTTP_HOST']
  end

  def scheme
    request.scheme
  end

  def url_no_scheme(path = '')
    "//#{host}#{path}"
  end

  def url(path = '')
    "#{scheme}://#{host}#{path}"
  end

  def authenticator
    @authenticator ||= Koala::Facebook::OAuth.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end

end

# the facebook session expired! reset ours and restart the process
error(Koala::Facebook::APIError) do
  session[:access_token] = nil
  redirect "/auth/facebook"
end

get "/" do
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if session[:access_token]
    @user    = @graph.get_object("me")
    @friends = @graph.get_connections('me', 'friends')
    @photos  = @graph.get_connections('me', 'photos')
    @likes   = @graph.get_connections('me', 'likes').first(4)

    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")
  end
  erb :index
end

# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect "/"
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

get "/sign_out" do
  session[:access_token] = nil
  redirect '/'
end

get "/auth/facebook" do
  session[:access_token] = nil
  redirect authenticator.url_for_oauth_code(:permissions => FACEBOOK_SCOPE)
end

get '/auth/facebook/callback' do
	session[:access_token] = authenticator.get_access_token(params[:code])
	redirect '/'
end


get '/graph' do
  log.info("graph")
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if session[:access_token]
    @friends = @graph.get_connections('me', 'friends')
    @friends.each do |friend|
      log.info("mutualfriends/#{friend['name']}")
      @mutualFriends = @graph.get_connections("me", "mutualfriends/#{friend['id']}")
      @peso = @mutualFriends.count().to_f*50.to_f/@friends.count().to_f
      log.info(@peso)
    end
  end

end


get '/o' do

  neo = Neography::Rest.new

  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])
  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if session[:access_token]

    @user    = @graph.get_object("me")
    @friends = @graph.get_connections('me', 'friends')
    commands = []

    sizes = {}
    mutuals = {}
    indexes = {}

    @friends.each do |friend|
      mutuals[friend['id']] = @graph.get_connections("me","mutualfriends/#{friend['id']}")
      peso = mutuals[friend['id']].count().to_f*50.to_f/@friends.count().to_f
      sizes[friend['id']]=peso
    end


    for n in 0..(@friends.count()-1)
      values = {name: @friends[n]['name'],
                uid:  @friends[n]['id'],
                size: sizes[@friends[n]['id']],
                r: 233,
                g: 233,
                b: 233,
                x: rand(600) - 300,
                y: rand(150) - 150}
      commands << [:create_node, values]

      indexes[@friends[n]['id']] = n
    end

    for n in 0..(@friends.count()-1)
      commands << [:add_node_to_index, "nodes_index", "type", "User", "{#{n}}"]

      mutuals[@friends[n]['id']].each do |mutual_friend|
        from = indexes[@friends[n]['id']]
        to = indexes[mutual_friend['id']]
        commands << [:create_relationship, "follows", "{#{from}}", "{#{to}}"]  unless to == from
      end
    end

    batch_result = neo.batch *commands
    log.info("Done!")
  end
  erb :graph
end


def nodes
  neo = Neography::Rest.new
  cypher_query =  " START node = node:nodes_index(type='User')"
  cypher_query << " RETURN ID(node), node"
  neo.execute_query(cypher_query)["data"].collect{|n| {"id" => n[0]}.merge(n[1]["data"])}
end

def edges
  neo = Neography::Rest.new
  cypher_query =  " START source = node:nodes_index(type='User')"
  cypher_query << " MATCH source -[rel]-> target"
  cypher_query << " RETURN ID(rel), ID(source), ID(target)"
  neo.execute_query(cypher_query)["data"].collect{|n| {"id" => n[0], "source" => n[1], "target" => n[2]} }
end


get '/graph.xml' do
  neo = Neography::Rest.new
  @nodes = nodes
  @edges = edges
  builder :graph
end