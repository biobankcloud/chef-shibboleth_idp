# Make sure we have what we need to unpack archives
package "unzip" do
  action :install
end

shibboleth_idp_supportfiles "default" do
  notifies :run, "bash[run_installer]", :immediately
end

bash "run_installer" do
  action :nothing
  cwd node['shibboleth_idp']["installer_dir"]
  code <<-EOH
    rm -rf "#{node['shibboleth_idp']['home']}"
    umask 0022 && echo -e "#{node['shibboleth_idp']["home"]}\n#{node['shibboleth_idp']["domain"]}\n#{node['shibboleth_idp']["keystore_pass"]}\n" \
     | JAVA_HOME=#{node['java']['java_home']} "#{node['shibboleth_idp']["installer_dir"]}/install.sh"
    EOH
end

# The IdP writes to these, so they should be owned by the Tomcat user
directory "#{node['shibboleth_idp']["home"]}/logs" do
  owner node["tomcat"]["user"]
  group node["tomcat"]["group"]
  mode "0755"
end
directory "#{node['shibboleth_idp']["home"]}/metadata" do
  owner node["tomcat"]["user"]
  group node["tomcat"]["group"]
  mode "0755"
end

# Put "endorsed" jars in a special place for Tomcat
directory "#{node['shibboleth_idp']['home']}/lib" do
  mode "0755"
end
directory "#{node['shibboleth_idp']['home']}/lib/endorsed" do
  mode "0755"
end
if File.directory?("#{node['shibboleth_idp']['home']}/lib/endorsed")
  Dir.foreach("#{node['shibboleth_idp']['home']}/lib/endorsed") do |item|
    # Symlink only jar files
    next if not item =~ /.*\.jar$/
    link "#{node['tomcat']['endorsed_dir']}/#{item}" do
      to "#{node['shibboleth_idp']['home']}/lib/endorsed/#{item}"
    end
  end
end

# Load the IdP war file without having to move it into the webapps directory
template "#{node['tomcat']['config_dir']}/Catalina/localhost/idp.xml" do
  source "idp.xml.erb"
  mode 0644
end

template "#{node['shibboleth_idp']['home']}/conf/internal.xml" do
  source "internal.xml.erb"
  mode 0644
  action :create
end

template "#{node['shibboleth_idp']['home']}/conf/handler.xml" do
  source "handler.xml.erb"
  mode 0644
end

template "#{node['shibboleth_idp']['home']}/conf/login.config" do
  source "login.config.erb"
  mode "0644"
  variables(
    :mods => node["shibboleth_idp"]["login_modules"]
  )
end

template "#{node['shibboleth_idp']['home']}/conf/relying-party.xml" do
  source "relying-party.xml.erb"
  mode "0644"
  variables(
    :remotemetadata => node["shibboleth_idp"]["remote_metadata"],
    :metadatadirs => node["shibboleth_idp"]["metadata_directories"],
    :relyingparties => node["shibboleth_idp"]["relying_parties"]
  )
end

template "#{node['shibboleth_idp']['home']}/conf/logging.xml" do
  source "logging.xml.erb"
  mode "0644"
  variables(
    :loggers => node["shibboleth_idp"]["loggers"]
  )
end

template "#{node['shibboleth_idp']['home']}/conf/attribute-resolver.xml" do
  source "attribute-resolver.xml.erb"
  mode "0644"
  variables(
    :attributes => node["shibboleth_idp"]["attributes"],
    :ldapresolvers => node["shibboleth_idp"]["ldap_resolvers"],
    :staticresolvers => node["shibboleth_idp"]["static_resolvers"],
    :computedresolvers => node["shibboleth_idp"]["computed_resolvers"]
  )
end

# Create the js files used by type=script attributes
node["shibboleth_idp"]["attributes"].each do |key,value|
  if value.has_key?('script')
    cookbook_file "#{node['shibboleth_idp']['home']}/conf/#{value['script']}" do
      mode "644"
    end
  end
end

template "#{node['shibboleth_idp']['home']}/conf/attribute-filter.xml" do
  source "attribute-filter.xml.erb"
  mode "0644"
  variables(
    :release => node["shibboleth_idp"]["relying_parties"]
  )
end

file "#{node['shibboleth_idp']['home']}/credentials/idp.crt" do
  mode "0644"
  content "#{node['shibboleth_idp']['idp_certificate']}"
end
file "#{node['shibboleth_idp']['home']}/credentials/idp.key" do
  # Should not be readable by random users, but must be for Tomcat
  group node["tomcat"]["group"]
  mode "0640"
  content "#{node['shibboleth_idp']['idp_key']}"
end

# Import certificates into the java trusted list. This is necessary to
# e.g. connect to an LDAPS server
node["shibboleth_idp"]["trust_certificates"].each do |name,cert|
  file "#{node['shibboleth_idp']['home']}/credentials/#{name}.crt" do
    mode "0644"
    content "#{cert}"
    notifies :run, "bash[#{name}]", :immediately
  end
  bash "#{name}" do
    action :nothing # Only run if triggered by the cert being created
    code <<-EOH
      #{node['java']['java_home']}/bin/keytool -import -trustcacerts \
       -alias "#{name}" \
       -file #{node['shibboleth_idp']['home']}/credentials/#{name}.crt \
       -keystore #{node['java']['java_home']}/jre/lib/security/cacerts \
       -storepass changeit -noprompt
    EOH
    not_if <<-EOH
      #{node['java']['java_home']}/bin/keytool -list \
       -keystore #{node['java']['java_home']}/jre/lib/security/cacerts \
       -alias "#{name}" -storepass changeit
    EOH
  end
end

# TODO - Place a link to servet jar file in Shibboleth lib directory to
# allow for use of aacli.sh
