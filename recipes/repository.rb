#
# Cookbook:: datadog
# Recipe:: repository
# Copyright:: 2013-2015, Datadog
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Repository configuration
yum_a5_architecture_map = {
  'i686' => 'i386',
  'i386' => 'i386',
  'x86' => 'i386'
}
yum_a5_architecture_map.default = 'x86_64'

agent_major_version = Chef::Datadog.agent_major_version(node)

# DATADOG_APT_KEY_CURRENT always contains the key that is used to sign repodata and latest packages
# A2923DFF56EDA6E76E55E492D3A80E30382E94DE expires in 2022
# D75CEA17048B9ACBF186794B32637D44F14F620E expires in 2032
apt_gpg_keys = {
  'DATADOG_APT_KEY_CURRENT.public'           => 'https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public',
  'D75CEA17048B9ACBF186794B32637D44F14F620E' => 'https://keys.datadoghq.com/DATADOG_APT_KEY_F14F620E.public',
  'A2923DFF56EDA6E76E55E492D3A80E30382E94DE' => 'https://keys.datadoghq.com/DATADOG_APT_KEY_382E94DE.public',
}
apt_trusted_d_keyring = '/etc/apt/trusted.gpg.d/datadog-archive-keyring.gpg'
apt_usr_share_keyring = '/usr/share/keyrings/datadog-archive-keyring.gpg'
apt_sources_list_file = '/etc/apt/sources.list.d/datadog.list'
apt_repo_uri = 'https://apt.datadoghq.com'

# DATADOG_RPM_KEY_CURRENT always contains the key that is used to sign repodata and latest packages
# DATADOG_RPM_KEY_E09422B3.public expires in 2022
# DATADOG_RPM_KEY_FD4BF915.public expires in 2024
rpm_gpg_keys = [['DATADOG_RPM_KEY_CURRENT.public', 'current', ''],
                ['DATADOG_RPM_KEY_E09422B3.public', 'e09422b3', 'A4C0 B90D 7443 CF6E 4E8A  A341 F106 8E14 E094 22B3'],
                ['DATADOG_RPM_KEY_FD4BF915.public', 'fd4bf915', 'C655 9B69 0CA8 82F0 23BD  F3F6 3F4D 1729 FD4B F915']]

# Local file name of the key
rpm_gpg_keys_name = 0
# Short fingerprint for rpm commands, used in "rpm -q gpg-pubkey-*" and node['datadog']["yumrepo_gpgkey_new_*"]
rpm_gpg_keys_short_fingerprint = 1
# Space delimited full fingerprint
rpm_gpg_keys_full_fingerprint = 2

case node['platform_family']
when 'debian'
  log 'apt deprecated parameters warning' do
    level :warn
    message 'Attributes "aptrepo_use_backup_keyserver", "aptrepo_keyserver" and "aptrepo_backup_keyserver" are deprecated since version 4.11.0'
    only_if {
      !node['datadog']['aptrepo_use_backup_keyserver'].nil? || !node['datadog']['aptrepo_keyserver'].nil? || !node['datadog']['aptrepo_backup_keyserver'].nil?
    }
  end

  apt_update 'update'

  package 'install-apt-transport-https' do
    package_name 'apt-transport-https'
    action :install
  end

  package 'install-gnupg' do
    package_name 'gnupg'
    action :install
  end

  file apt_usr_share_keyring do
    action :create_if_missing
    content ''
    mode '0644'
  end

  apt_gpg_keys.each do |key_fingerprint, key_url|
    # Download the APT key
    key_local_path = ::File.join(Chef::Config[:file_cache_path], key_fingerprint)
    # By default, remote_file will use `If-Modified-Since` header to see if the file
    # was modified remotely, so this works fine for the "current" key
    remote_file "remote_file_#{key_fingerprint}" do
      path key_local_path
      source key_url
      notifies :run, "execute[import apt datadog key #{key_fingerprint}]", :immediately
    end

    # Import the APT key
    execute "import apt datadog key #{key_fingerprint}" do
      command "/bin/cat #{key_local_path} | gpg --import --batch --no-default-keyring --keyring #{apt_usr_share_keyring}"
      # the second part extracts the fingerprint of the key from output like "fpr::::A2923DFF56EDA6E76E55E492D3A80E30382E94DE:"
      not_if "/usr/bin/gpg --no-default-keyring --keyring #{apt_usr_share_keyring} --list-keys --with-fingerprint --with-colons | grep \
             $(cat #{key_local_path} | gpg --with-colons --with-fingerprint 2>/dev/null | grep 'fpr:' | sed 's|^fpr||' | tr -d ':')"
      action :nothing
    end
  end

  remote_file apt_trusted_d_keyring do
    action :create
    mode '0644'
    source "file://#{apt_usr_share_keyring}"
    only_if { (platform?('ubuntu') && node['platform_version'].to_i < 16) || (platform?('debian') && node['platform_version'].to_i < 9) }
  end

  case agent_major_version
  when 7
    components = ['7']
  when 6
    components = ['6']
  when 5
    components = ['main']
  else
    Chef::Log.error("agent_major_version '#{agent_major_version}' not supported.")
  end

  retries = node['datadog']['aptrepo_retries']

  # Add APT repositories
  # Chef's apt_repository resource doesn't allow specifying the signed-by option and we can't pass
  # it in uri, as that would make it fail parsing, hence we use the file and apt_update resources.
  apt_update 'datadog' do
    retries retries
    ignore_failure true # this is exactly what apt_repository does
    action :nothing
  end

  deb_repo_with_options = if node['datadog']['aptrepo'].nil?
                            "[signed-by=#{apt_usr_share_keyring}] #{apt_repo_uri}"
                          else
                            node['datadog']['aptrepo']
                          end

  file apt_sources_list_file do
    action :create
    owner 'root'
    group 'root'
    mode '0644'
    content "deb #{deb_repo_with_options} #{node['datadog']['aptrepo_dist']} #{components.compact.join(' ')}"
    notifies :update, 'apt_update[datadog]', :immediately
  end

  # Previous versions of the cookbook could create these repo files, make sure we remove it now
  apt_repository 'datadog-beta' do
    action :remove
  end

  apt_repository 'datadog_apt_A2923DFF56EDA6E76E55E492D3A80E30382E94DE' do
    action :remove
  end

  apt_repository 'datadog_apt_D75CEA17048B9ACBF186794B32637D44F14F620E' do
    action :remove
  end

when 'rhel', 'fedora', 'amazon'
  # gnupg is required to check the downloaded key's fingerprint
  package 'gnupg' do
    action :install
    only_if { node['packages']['gnupg2'].nil? }
  end

  # Import new RPM key
  rpm_gpg_keys.each do |rpm_gpg_key|
    next unless node['datadog']["yumrepo_gpgkey_new_#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}"]

    # Download new RPM key
    key_local_path = ::File.join(Chef::Config[:file_cache_path], rpm_gpg_key[rpm_gpg_keys_name])
    remote_file "remote_file_#{rpm_gpg_key[rpm_gpg_keys_name]}" do
      path key_local_path
      source node['datadog']["yumrepo_gpgkey_new_#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}"]
      # note that for the "current" key, this will fine, because there's never going to be
      # gpg-pubkey-current entry in the RPM database
      not_if "rpm -q gpg-pubkey-#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}" # (key already imported)
      notifies :run, "execute[rpm-import datadog key #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}]", :immediately
    end

    # The fingerprint string has spaces in it, calculate one without space here
    gpg_key_fingerprint_without_space = rpm_gpg_key[rpm_gpg_keys_full_fingerprint].delete(' ')

    # Import key if fingerprint matches
    execute "rpm-import datadog key #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}" do
      command "rpm --import #{key_local_path}"
      only_if "gpg --dry-run --quiet --with-fingerprint #{key_local_path} | grep '#{rpm_gpg_key[rpm_gpg_keys_full_fingerprint]}' || gpg --dry-run --import --import-options import-show #{key_local_path} | grep '#{gpg_key_fingerprint_without_space}' || [ #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]} = \"current\" ]"
      action :nothing
    end
  end

  # When the user has set yumrepo_repo_gpgcheck explicitly, we respect that.
  # Otherwise, we turn on repo_gpgcheck by default when both:
  # * We're not running on RHEL/CentOS 5 or older
  # * User has not overriden the default yumrepo
  # * System is not RHEL/CentOS 8.1 (repo_gpgcheck doesn't work there because
  #   of https://bugzilla.redhat.com/show_bug.cgi?id=1792506
  repo_gpgcheck = if node['datadog']['yumrepo_repo_gpgcheck'].nil?
                    if !node['datadog']['yumrepo'].nil? || (platform_family?('rhel') && node['platform_version'].to_i < 6) ||
                       (platform?('centos', 'redhat') && node['platform_version'].to_f >= 8.1 && node['platform_version'].to_f < 8.2)
                      false
                    else
                      true
                    end
                  else
                    node['datadog']['yumrepo_repo_gpgcheck']
                  end

  if !node['datadog']['yumrepo'].nil?
    baseurl = node['datadog']['yumrepo']
  else
    # Older versions of yum embed M2Crypto with SSL that doesn't support TLS1.2
    yum_protocol_a5 = platform_family?('rhel') ? 'http' : 'https'
    case agent_major_version
    when 6, 7
      baseurl = "https://yum.datadoghq.com/stable/#{agent_major_version}/#{node['kernel']['machine']}/"
    when 5
      baseurl = "#{yum_protocol_a5}://yum.datadoghq.com/rpm/#{yum_a5_architecture_map[node['kernel']['machine']]}/"
      repo_gpgcheck = false
    else
      Chef::Log.error("agent_major_version '#{agent_major_version}' not supported.")
    end
  end

  # Add YUM repository
  yumrepo_gpgkeys = []
  if agent_major_version > 5
    rpm_gpg_keys.each do |rpm_gpg_key|
      yumrepo_gpgkeys.push(node['datadog']["yumrepo_gpgkey_new_#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}"])
    end
  end
  # yum/dnf go through entries in the order in which they're set in the repofile;
  # add the old key last so it doesn't get imported at all if a newer key can be used
  yumrepo_gpgkeys.push(node['datadog']['yumrepo_gpgkey']) if agent_major_version < 7

  yum_repository 'datadog' do
    description 'datadog'
    baseurl baseurl
    proxy node['datadog']['yumrepo_proxy']
    proxy_username node['datadog']['yumrepo_proxy_username']
    proxy_password node['datadog']['yumrepo_proxy_password']
    gpgkey yumrepo_gpgkeys
    gpgcheck true
    repo_gpgcheck repo_gpgcheck
    action :create
  end
when 'suse'
  # Import new RPM key
  rpm_gpg_keys.each do |rpm_gpg_key|
    next unless node['datadog']["yumrepo_gpgkey_new_#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}"]

    # Download new RPM key
    new_key_local_path = ::File.join(Chef::Config[:file_cache_path], rpm_gpg_key[rpm_gpg_keys_name])
    remote_file "remote_file_#{rpm_gpg_key[rpm_gpg_keys_name]}" do
      path new_key_local_path
      source node['datadog']["yumrepo_gpgkey_new_#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}"]
      not_if "rpm -q gpg-pubkey-#{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}" # (key already imported)
      notifies :run, "execute[rpm-import datadog key #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}]", :immediately
    end

    # The fingerprint string has spaces in it, calculate one without space here
    gpg_key_fingerprint_without_space = rpm_gpg_key[rpm_gpg_keys_full_fingerprint].delete(' ')

    # Import key if fingerprint matches
    execute "rpm-import datadog key #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]}" do
      command "rpm --import #{new_key_local_path}"
      only_if "gpg --dry-run --quiet --with-fingerprint #{new_key_local_path} | grep '#{rpm_gpg_key[rpm_gpg_keys_full_fingerprint]}' || gpg --dry-run --import --import-options import-show #{new_key_local_path} | grep '#{gpg_key_fingerprint_without_space}' || [ #{rpm_gpg_key[rpm_gpg_keys_short_fingerprint]} = \"current\" ]"
      action :nothing
    end
  end

  # Now the old key is mostly hard-coded
  old_key_local_path = ::File.join(Chef::Config[:file_cache_path], 'DATADOG_RPM_KEY.public')
  remote_file 'DATADOG_RPM_KEY.public' do
    path old_key_local_path
    source node['datadog']['yumrepo_gpgkey']
    not_if 'rpm -q gpg-pubkey-4172a230' # (key already imported)
    notifies :run, 'execute[rpm-import datadog key 4172a230]', :immediately
  end

  # Import key if fingerprint matches
  execute 'rpm-import datadog key 4172a230' do
    command "rpm --import #{old_key_local_path}"
    only_if "gpg --dry-run --quiet --with-fingerprint #{old_key_local_path} | grep '60A3 89A4 4A0C 32BA E3C0  3F0B 069B 56F5 4172 A230' || gpg --dry-run --import --import-options import-show #{old_key_local_path} | grep '60A389A44A0C32BAE3C03F0B069B56F54172A230'"
    action :nothing
  end

  if !node['datadog']['yumrepo_suse'].nil?
    baseurl = node['datadog']['yumrepo_suse']
  else
    case agent_major_version
    when 6, 7
      baseurl = "https://yum.datadoghq.com/suse/stable/#{agent_major_version}/#{node['kernel']['machine']}/"
    when 5
      baseurl = "https://yum.datadoghq.com/suse/rpm/#{yum_a5_architecture_map[node['kernel']['machine']]}/"
    else
      Chef::Log.error("agent_major_version '#{agent_major_version}' not supported.")
    end
  end

  # Add YUM repository
  zypper_repository 'datadog' do
    description 'datadog'
    baseurl baseurl
    gpgkey agent_major_version < 6 ? node['datadog']['yumrepo_gpgkey'] : node['datadog']['yumrepo_gpgkey_new_current']
    gpgautoimportkeys false
    gpgcheck false
    # zypper has no repo_gpgcheck option, but it does repodata signature checks
    # by default (when the repomd.xml.asc file is present) which users have
    # to actually disable system-wide, so we are fine not setting it explicitly
    action :create
  end
end
