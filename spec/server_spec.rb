# encoding: UTF-8
#

require_relative 'spec_helper'

describe 'openstack-identity::server' do
  describe 'ubuntu' do
    let(:runner) { ChefSpec::Runner.new(UBUNTU_OPTS) }
    let(:node) { runner.node }
    let(:chef_run) do
      node.set_unless['openstack']['endpoints']['identity-bind'] = {
        'host' => '127.0.1.1'
      }
      node.set_unless['openstack']['endpoints']['identity-api'] = {
        'host' => '127.0.1.1',
        'port' => '5000',
        'scheme' => 'https'
      }
      node.set_unless['openstack']['endpoints']['identity-admin'] = {
        'host' => '127.0.1.1',
        'port' => '35357',
        'scheme' => 'https'
      }
      node.set_unless['openstack']['endpoints']['identity-admin-bind'] = {
        'host' => '127.0.1.1',
        'port' => '35357'
      }

      runner.converge(described_recipe)
    end

    include Helpers
    include_context 'identity_stubs'

    it 'runs logging recipe if node attributes say to' do
      node.set['openstack']['identity']['syslog']['use'] = true
      expect(chef_run).to include_recipe('openstack-common::logging')
    end

    it 'does not run logging recipe' do
      expect(chef_run).not_to include_recipe('openstack-common::logging')
    end

    it 'converges when configured to use sqlite db backend' do
      node.set['openstack']['db']['identity']['service_type'] = 'sqlite'
      expect { chef_run }.to_not raise_error
    end

    it 'upgrades mysql python packages' do
      expect(chef_run).to upgrade_package('identity cookbook package python-mysqldb')
    end

    it 'upgrades postgresql python packages if explicitly told' do
      node.set['openstack']['db']['identity']['service_type'] = 'postgresql'
      expect(chef_run).to upgrade_package('identity cookbook package python-psycopg2')
    end

    it 'upgrades memcache python packages' do
      expect(chef_run).to upgrade_package('identity cookbook package python-memcache')
    end

    it 'upgrades keystone packages' do
      expect(chef_run).to upgrade_package('identity cookbook package keystone')
    end

    it 'starts keystone on boot' do
      expect(chef_run).to enable_service('keystone')
    end

    it 'sleep on keystone service enable' do
      expect(chef_run.service('keystone')).to notify(
        'execute[Keystone: sleep]').to(:run)
    end

    it 'has flush tokens cronjob running every day at 3:30am' do
      expect(chef_run).to create_cron('keystone-manage-token-flush').with_command(/keystone-manage token_flush/)
      expect(chef_run).to create_cron('keystone-manage-token-flush').with_minute('0')
      expect(chef_run).to create_cron('keystone-manage-token-flush').with_hour('*')
      expect(chef_run).to create_cron('keystone-manage-token-flush').with_day('*')
      expect(chef_run).to create_cron('keystone-manage-token-flush').with_weekday('*')
    end

    it 'deletes flush tokens cronjob when tokens backend is not sql' do
      node.set['openstack']['identity']['token']['backend'] = 'notsql'
      expect(chef_run).to delete_cron('keystone-manage-token-flush')
    end

    describe '/etc/keystone' do
      let(:dir) { chef_run.directory('/etc/keystone') }

      it 'has proper owner' do
        expect(dir.owner).to eq('keystone')
        expect(dir.group).to eq('keystone')
      end

      it 'has proper modes' do
        expect(sprintf('%o', dir.mode)).to eq('700')
      end
    end

    describe '/etc/keystone/domains' do
      let(:dir) { '/etc/keystone/domains' }

      it 'does not create /etc/keystone/domains by default' do
        expect(chef_run).not_to create_directory(dir)
      end

      it 'creates /etc/keystone/domains when domain_specific_drivers_enabled enabled' do
        node.set['openstack']['identity']['identity']['domain_specific_drivers_enabled'] = true
        expect(chef_run).to create_directory(dir).with(
          user: 'keystone',
          group: 'keystone',
          mode: 0700
        )
      end
    end

    describe 'ssl directories' do
      let(:ssl_dir) { '/etc/keystone/ssl' }
      let(:certs_dir) { "#{ssl_dir}/certs" }
      let(:private_dir) { "#{ssl_dir}/private" }

      describe 'without pki' do
        before { node.set['openstack']['auth']['strategy'] = 'uuid' }

        it 'does not create /etc/keystone/ssl' do
          expect(chef_run).not_to create_directory(ssl_dir)
        end

        it 'does not create /etc/keystone/ssl/certs' do
          expect(chef_run).not_to create_directory(certs_dir)
        end

        it 'does not create /etc/keystone/ssl/private' do
          expect(chef_run).not_to create_directory(private_dir)
        end
      end

      describe 'with pki' do
        describe '/etc/keystone/ssl' do
          let(:dir_resource) { chef_run.directory(ssl_dir) }

          it 'creates /etc/keystone/ssl' do
            expect(chef_run).to create_directory(ssl_dir)
          end

          it 'has proper owner' do
            expect(dir_resource.owner).to eq('keystone')
            expect(dir_resource.group).to eq('keystone')
          end

          it 'has proper modes' do
            expect(sprintf('%o', dir_resource.mode)).to eq('700')
          end
        end

        describe '/etc/keystone/ssl/certs' do
          let(:dir_resource) { chef_run.directory(certs_dir) }

          it 'creates /etc/keystone/ssl/certs' do
            expect(chef_run).to create_directory(certs_dir)
          end

          it 'has proper owner' do
            expect(dir_resource.owner).to eq('keystone')
            expect(dir_resource.group).to eq('keystone')
          end

          it 'has proper modes' do
            expect(sprintf('%o', dir_resource.mode)).to eq('755')
          end
        end

        describe '/etc/keystone/ssl/private' do
          let(:dir_resource) { chef_run.directory(private_dir) }

          it 'creates /etc/keystone/ssl/private' do
            expect(chef_run).to create_directory(private_dir)
          end

          it 'has proper owner' do
            expect(dir_resource.owner).to eq('keystone')
            expect(dir_resource.group).to eq('keystone')
          end

          it 'has proper modes' do
            expect(sprintf('%o', dir_resource.mode)).to eq('750')
          end
        end
      end
    end

    describe 'ssl files' do
      describe 'with pki' do
        describe 'with {certfile,keyfile,ca_certs}_url attributes set' do
          before do
            node.set['openstack']['identity']['signing']['certfile_url'] = 'http://www.test.com/signing_cert.pem'
            node.set['openstack']['identity']['signing']['keyfile_url']  = 'http://www.test.com/signing_key.pem'
            node.set['openstack']['identity']['signing']['ca_certs_url'] = 'http://www.test.com/ca.pem'
          end

          describe 'cert file' do
            let(:cert_file) { node['openstack']['identity']['signing']['certfile'] }
            let(:file_resource) { chef_run.remote_file(cert_file) }

            it 'creates files' do
              expect(chef_run).to create_remote_file(cert_file)
            end

            it 'has proper owner' do
              expect(file_resource.owner).to eq('keystone')
              expect(file_resource.group).to eq('keystone')
            end

            it 'has proper modes' do
              expect(sprintf('%o', file_resource.mode)).to eq('640')
            end

            it 'notifies keystone restart' do
              expect(file_resource).to notify('service[keystone]').to(:restart)
            end
          end

          describe 'key file' do
            let(:key_file) { node['openstack']['identity']['signing']['keyfile'] }
            let(:file_resource) { chef_run.remote_file(key_file) }

            it 'creates file' do
              expect(chef_run).to create_remote_file(key_file)
            end

            it 'has proper owner' do
              expect(file_resource.owner).to eq('keystone')
              expect(file_resource.group).to eq('keystone')
            end

            it 'has proper modes' do
              expect(sprintf('%o', file_resource.mode)).to eq('640')
            end

            it 'notifies keystone restart' do
              expect(file_resource).to notify('service[keystone]').to(:restart)
            end
          end

          describe 'ca_certs' do
            let(:ca_certs) { node['openstack']['identity']['signing']['ca_certs'] }
            let(:file_resource) { chef_run.remote_file(ca_certs) }

            it 'creates file' do
              expect(chef_run).to create_remote_file(ca_certs)
            end

            it 'has proper owner' do
              expect(file_resource.owner).to eq('keystone')
              expect(file_resource.group).to eq('keystone')
            end

            it 'has proper modes' do
              expect(sprintf('%o', file_resource.mode)).to eq('640')
            end

            it 'notifies keystone restart' do
              expect(file_resource).to notify('service[keystone]').to(:restart)
            end
          end
        end

        describe 'without {certfile,keyfile,ca_certs}_url attributes set' do
          it 'does not create cert file' do
            expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['certfile'])
          end

          it 'does not create key file' do
            expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['keyfile'])
          end

          it 'does not create ca_certs file' do
            expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['ca_certs'])
          end
        end
      end

      describe 'without pki' do
        before { node.set['openstack']['auth']['strategy'] = 'uuid' }

        it 'does not create cert file' do
          expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['certfile'])
        end

        it 'does not create key file' do
          expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['keyfile'])
        end

        it 'does not create ca_certs file' do
          expect(chef_run).not_to create_remote_file(node['openstack']['identity']['signing']['ca_certs'])
        end
      end
    end

    it 'deletes keystone.db' do
      expect(chef_run).to delete_file('/var/lib/keystone/keystone.db')
    end

    it 'does not delete keystone.db when configured to use sqlite' do
      node.set['openstack']['db']['identity']['service_type'] = 'sqlite'
      expect(chef_run).not_to delete_file('/var/lib/keystone/keystone.db')
    end

    describe 'pki setup' do
      let(:cmd) { 'keystone-manage pki_setup' }

      describe 'without pki' do
        before { node.set['openstack']['auth']['strategy'] = 'uuid' }
        it 'does not execute' do
          expect(chef_run).to_not run_execute(cmd).with(
            user: 'keystone',
            group: 'keystone'
          )
        end
      end

      describe 'with pki' do
        describe 'without {certfile,keyfile,ca_certs}_url attributes set' do
          it 'executes' do
            expect(FileTest).to receive(:exists?)
              .with('/etc/keystone/ssl/private/signing_key.pem')
              .and_return(false)

            expect(chef_run).to run_execute(cmd).with(
              user: 'keystone',
              group: 'keystone'
            )
          end
        end

        describe 'with {certfile,keyfile,ca_certs}_url attributes set' do
          before do
            node.set['openstack']['identity']['signing']['certfile_url'] = 'http://www.test.com/signing_cert.pem'
            node.set['openstack']['identity']['signing']['keyfile_url']  = 'http://www.test.com/signing_key.pem'
            node.set['openstack']['identity']['signing']['ca_certs_url'] = 'http://www.test.com/ca.pem'
          end

          it 'does not execute' do
            expect(chef_run).to_not run_execute(cmd).with(
              user: 'keystone',
              group: 'keystone'
            )
          end
        end

        it 'does not execute when dir exists' do
          expect(FileTest).to receive(:exists?)
            .with('/etc/keystone/ssl/private/signing_key.pem')
            .and_return(true)

          expect(chef_run).not_to run_execute(cmd).with(
            user: 'keystone',
            group: 'keystone'
          )
        end
      end
    end

    describe 'keystone.conf' do
      let(:path) { '/etc/keystone/keystone.conf' }
      let(:resource) { chef_run.template(path) }

      describe 'file properties' do
        it 'has correct owner' do
          expect(resource.owner).to eq('keystone')
          expect(resource.group).to eq('keystone')
        end

        it 'has correct modes' do
          expect(sprintf('%o', resource.mode)).to eq('640')
        end
      end

      describe '[eventlet_server_ssl] section' do
        opts = {
            enable: 'True',
            certfile: '/etc/keystone/ssl/certs/sslcert.pem',
            keyfile: '/etc/keystone/ssl/private/sslkey.pem',
            ca_certs: '/etc/keystone/ssl/certs/sslca.pem',
            cert_required: 'false'
        }
        describe 'with ssl enabled' do
          before do
            node.set['openstack']['identity']['ssl']['enabled'] = true
            node.set['openstack']['identity']['ssl']['basedir'] = '/etc/keystone/ssl'
          end
          describe 'with client cert not required' do
            it 'configures ssl options without client certificate' do
              opts.each do |key, val|
                r = line_regexp("#{key} = #{val}")
                expect(chef_run).to render_config_file(path).with_section_content('eventlet_server_ssl', r)
              end
            end
          end
          describe 'with client cert required' do
            before do
              node.set['openstack']['identity']['ssl']['cert_required'] = true
              opts['cert_required'.to_sym] = 'true'
            end
            it 'configures ssl options with client certificate' do
              opts.each do |key, val|
                r = line_regexp("#{key} = #{val}")
                expect(chef_run).to render_config_file(path).with_section_content('eventlet_server_ssl', r)
              end
            end
          end
        end

        describe 'without ssl disabled' do
          before { node.set['openstack']['identity']['ssl']['enabled'] = false }
          it 'does not configure ssl options' do
            opts.each do |key, val|
              expect(chef_run).not_to render_config_file(path).with_section_content('eventlet_server_ssl', /^#{key} = /)
            end
          end
        end
      end

      describe '[saml] section' do
        describe 'saml attributes' do
          saml_default_attrs = %w(assertion_expiration_time=3600
                                  xmlsec1_binary=xmlsec1
                                  certfile=
                                  keyfile=)
          it 'default saml attributes' do
            saml_default_attrs.each do |attr|
              default_value = /^#{attr}$/
              expect(chef_run).to render_config_file(path).with_section_content('saml', default_value)
            end
          end

          saml_override_attrs = %w(assertion_expiration_time
                                   xmlsec1_binary
                                   certfile
                                   keyfile)
          it 'override saml attributes' do
            saml_override_attrs.each do |attr|
              node.set['openstack']['identity']['saml']["#{attr}"] = "value_for_#{attr}"
              override_value = /^#{attr}=value_for_#{attr}$/
              expect(chef_run).to render_config_file(path).with_section_content('saml', override_value)
            end
          end
        end

        describe 'optional saml ipd attributes' do
          optional_attrs = %w{idp_entity_id idp_sso_endpoint idp_lang
                              idp_organization_name idp_organization_display_name
                              idp_organization_url idp_contact_company idp_contact_name
                              idp_contact_surname idp_contact_email idp_contact_telephone
                              idp_contact_type idp_metadata_path}
          it 'empty default ipd attributes' do
            optional_attrs.each do |attr|
              default_value = /^#{attr}=$/
              expect(chef_run).to render_config_file(path).with_section_content('saml', default_value)
            end
          end

          it 'overridden ipd attributes' do
            optional_attrs.each do |attr|
              node.set['openstack']['identity']['saml']["#{attr}"] = "value_for_#{attr}"
              override_value = /^#{attr}=value_for_#{attr}$/
              expect(chef_run).to render_config_file(path).with_section_content('saml', override_value)
            end
          end
        end
      end

      it 'has no list_limits by default' do
        expect(chef_run).not_to render_config_file(path).with_section_content('DEFAULT', /^list_limit=/)
      end

      it 'sets list limits correctly' do
        node.set['openstack']['identity']['list_limit'] = 111
        node.set['openstack']['identity']['assignment']['list_limit'] = 222
        node.set['openstack']['identity']['catalog']['list_limit'] = 333
        node.set['openstack']['identity']['identity']['list_limit'] = 444
        node.set['openstack']['identity']['policy']['list_limit'] = 555
        expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', /^list_limit=111$/)
        expect(chef_run).to render_config_file(path).with_section_content('assignment', /^list_limit=222$/)
        expect(chef_run).to render_config_file(path).with_section_content('catalog', /^list_limit=333$/)
        expect(chef_run).to render_config_file(path).with_section_content('identity', /^list_limit=444$/)
        expect(chef_run).to render_config_file(path).with_section_content('policy', /^list_limit=555$/)
      end

      it 'templates misc_keystone array correctly' do
        node.set['openstack']['identity']['misc_keystone'] = ['MISC1=OPTION1', 'MISC2=OPTION2']
        expect(chef_run).to render_file(path).with_content(
          /^MISC1=OPTION1$/)
        expect(chef_run).to render_file(path).with_content(
          /^MISC2=OPTION2$/)
      end

      it 'notifies keystone restart' do
        expect(resource).to notify('service[keystone]').to(:restart)
      end

      describe '[eventlet_server] section' do
        it 'has default worker values' do
          expect(chef_run).not_to render_config_file(path).with_section_content('eventlet_server', /^admin_workers=/)
          expect(chef_run).not_to render_config_file(path).with_section_content('eventlet_server', /^public_workers=/)
        end

        it 'has specific worker values' do
          node.set['openstack']['identity']['admin_workers'] = 123
          node.set['openstack']['identity']['public_workers'] = 456
          expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', /^admin_workers=123$/)
          expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', /^public_workers=456$/)
        end
        describe 'bind_interface is nil' do
          it 'has bind host from endpoint' do
            r = line_regexp('public_bind_host = 127.0.1.1')
            expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', r)
          end
        end

        describe 'bind_interface is eth0' do
          before do
            node.set['openstack']['endpoints']['identity-bind']['bind_interface'] = 'eth0'
            allow_any_instance_of(Chef::Recipe).to receive(:address_for)
              .and_return('10.0.0.2')
          end

          it 'has bind host from interface ip' do
            r = line_regexp('public_bind_host = 10.0.0.2')
            expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', r)
          end
        end

        describe 'admin bind_interface is nil' do
          it 'has admin bind host from endpoint' do
            r = line_regexp('admin_bind_host = 127.0.1.1')
            expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', r)
          end
        end

        describe 'admin bind_interface is eth0' do
          before do
            node.set['openstack']['endpoints']['identity-admin-bind']['bind_interface'] = 'eth0'
            allow_any_instance_of(Chef::Recipe).to receive(:address_for)
              .and_return('10.0.0.2')
          end

          it 'has admin bind host from interface ip' do
            r = line_regexp('admin_bind_host = 10.0.0.2')
            expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', r)
          end
        end

        describe 'port numbers' do
          ['public_port', 'admin_port'].each do |x|
            it "has #{x}" do
              expect(chef_run).to render_config_file(path).with_section_content('eventlet_server', /^#{x} = \d+$/)
            end
          end
        end
      end

      it 'has rpc_backend set for rabbit' do
        node.set['openstack']['mq']['service_type'] = 'rabbitmq'
        expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', /^rpc_backend = rabbit$/)
      end

      it 'has rpc_backend set for qpid' do
        node.set['openstack']['mq']['service_type'] = 'qpid'
        expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', /^rpc_backend = qpid$/)
      end

      describe '[DEFAULT] section' do
        it 'has admin token' do
          r = line_regexp('admin_token = bootstrap-token')
          expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', r)
        end

        describe 'logging verbosity' do
          ['verbose', 'debug'].each do |x|
            it "has #{x} option" do
              r = line_regexp("#{x} = False")
              expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', r)
            end
          end
        end

        describe 'syslog configuration' do
          log_file = /^log_file = \/\w+/
          log_conf = /^log_config_append = \/\w+/

          it 'renders log_file correctly' do
            expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', log_file)
            expect(chef_run).not_to render_config_file(path).with_section_content('DEFAULT', log_conf)
          end

          it 'renders log_config correctly' do
            node.set['openstack']['identity']['syslog']['use'] = true

            expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', log_conf)
            expect(chef_run).not_to render_config_file(path).with_section_content('DEFAULT', log_file)
          end
        end

        it 'has default for oslo.messaging configuration' do
          [/^notification_driver = messaging$/,
           /^notification_topics = notifications$/,
           /^rpc_thread_pool_size = 64$/,
           /^rpc_response_timeout = 60$/,
           /^rpc_backend = rabbit$/,
           /^control_exchange = openstack$/
          ].each do |line|
            expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', line)
          end
        end

        it 'has correct endpoints' do
          # values correspond to node attrs set in chef_run above
          pub = line_regexp('public_endpoint = https://127.0.1.1:5000/')
          adm = line_regexp('admin_endpoint = https://127.0.1.1:35357/')

          expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', pub)
          expect(chef_run).to render_config_file(path).with_section_content('DEFAULT', adm)
        end
      end

      describe '[memcache] section' do
        it 'has no servers by default' do
          # `Openstack#memcached_servers' is stubbed in spec_helper.rb to
          # return an empty array, so we expect an empty `servers' list.
          r = line_regexp('servers = ')
          expect(chef_run).to render_config_file(path).with_section_content('memcache', r)
        end

        it 'has servers when hostnames are configured' do
          # Re-stub `Openstack#memcached_servers' here
          hosts = ['host1:111', 'host2:222']
          r = line_regexp("servers = #{hosts.join(',')}")

          allow_any_instance_of(Chef::Recipe).to receive(:memcached_servers)
            .and_return(hosts)
          expect(chef_run).to render_config_file(path).with_section_content('memcache', r)
        end
      end

      describe '[sql] section' do
        it 'has a connection' do
          r = /^connection = \w+/
          expect(chef_run).to render_config_file(path).with_section_content('database', r)
        end
      end

      describe '[ldap] section' do
        describe 'optional nil attributes' do
          optional_attrs = %w{group_tree_dn group_filter user_filter
                              user_tree_dn user_enabled_emulation_dn
                              group_attribute_ignore role_attribute_ignore
                              role_tree_dn role_filter project_tree_dn
                              project_enabled_emulation_dn project_filter
                              project_attribute_ignore}

          it 'does not configure attributes' do
            optional_attrs.each do |a|
              r = /^#{Regexp.quote(a)} =$/
              expect(chef_run).not_to render_config_file(path).with_section_content('ldap', r)
            end
          end

          context 'ssl settings' do
            context 'when use_tls disabled' do
              it 'does not set tls_ options if use_tls is disabled' do
                [/^tls_cacertfile = /, /^tls_cacertdir = /, /^tls_req_cert = /].each do |setting|
                  expect(chef_run).not_to render_config_file(path).with_section_content('ldap', setting)
                end
              end
            end

            context 'when use_tls enabled' do
              before do
                node.set['openstack']['identity']['ldap']['use_tls'] = true
              end

              context 'when cert paths are configured' do
                it 'has a tls_cacertfile when configured' do
                  node.set['openstack']['identity']['ldap']['tls_cacertfile'] = 'tls_cacertfile_value'
                  expect(chef_run).to render_config_file(path).with_section_content('ldap', /^tls_cacertfile = tls_cacertfile_value$/)
                  expect(chef_run).not_to render_config_file(path).with_section_content('ldap', /^tls_cacertdir = /)
                end
                it 'has a tls_cacertdir when configured and tls_cacertfile unset' do
                  node.set['openstack']['identity']['ldap']['tls_cacertfile'] = nil
                  node.set['openstack']['identity']['ldap']['tls_cacertdir'] = 'tls_cacertdir_value'
                  expect(chef_run).to render_config_file(path).with_section_content('ldap', /^tls_cacertdir = tls_cacertdir_value$/)
                  expect(chef_run).not_to render_config_file(path).with_section_content('ldap', /^tls_cacertfile = /)
                end
              end

              context 'when tls_req_cert validation disabled' do
                it 'has a tls_req_cert set to never' do
                  node.set['openstack']['identity']['ldap']['tls_req_cert'] = 'never'
                  expect(chef_run).to render_config_file(path).with_section_content('ldap', /^tls_req_cert = never$/)
                end
              end
            end
          end

        end

        it 'has required attributes' do
          required_attrs = %w{alias_dereferencing allow_subtree_delete
                              dumb_member group_allow_create group_allow_delete
                              group_allow_update group_desc_attribute
                              group_id_attribute
                              group_member_attribute group_name_attribute
                              group_objectclass page_size query_scope
                              role_allow_create role_allow_delete
                              role_allow_update role_id_attribute
                              role_member_attribute role_name_attribute
                              role_objectclass suffix project_allow_create
                              project_allow_delete project_allow_update
                              project_desc_attribute project_domain_id_attribute
                              project_enabled_attribute project_enabled_emulation
                              project_id_attribute project_member_attribute
                              project_name_attribute project_objectclass url
                              use_dumb_member user user_allow_create
                              user_allow_delete user_allow_update
                              user_attribute_ignore
                              user_enabled_attribute user_enabled_default
                              user_enabled_emulation user_enabled_mask
                              user_id_attribute user_mail_attribute
                              user_name_attribute user_objectclass
                              user_pass_attribute}

          required_attrs.each do |a|
            expect(chef_run).to render_config_file(path).with_section_content('ldap', /^#{Regexp.quote(a)} = \w+/)
          end
        end
      end

      describe '[identity] section' do
        it 'configures driver' do
          r = line_regexp('driver = keystone.identity.backends.sql.Identity')
          expect(chef_run).to render_config_file(path).with_section_content('identity', r)
        end

        [
          /^default_domain_id=default$/,
          /^domain_specific_drivers_enabled=false$/,
          %r(^domain_config_dir=/etc/keystone/domains$)
        ].each do |line|
          it "has a #{line.source} line" do
            expect(chef_run).to render_config_file(path).with_section_content('identity', line)
          end
        end
      end

      describe '[assignment] section' do
        it 'configures driver' do
          r = line_regexp('driver = keystone.assignment.backends.sql.Assignment')
          expect(chef_run).to render_config_file(path).with_section_content('assignment', r)
        end
      end

      describe '[catalog] section' do
        # use let() to access Helpers#line_regexp method
        let(:templated) do
          str = 'driver = keystone.catalog.backends.templated.TemplatedCatalog'
          line_regexp(str)
        end
        let(:sql) do
          line_regexp('driver = keystone.catalog.backends.sql.Catalog')
        end

        it 'configures driver' do
          expect(chef_run).to render_config_file(path).with_content(sql)
          expect(chef_run).not_to render_config_file(path).with_section_content('catalog', templated)
        end

        it 'configures driver with templated backend' do
          node.set['openstack']['identity']['catalog']['backend'] = 'templated'

          expect(chef_run).to render_config_file(path).with_section_content('catalog', templated)
          expect(chef_run).not_to render_config_file(path).with_section_content('catalog', sql)
        end
      end

      describe '[token] section' do
        it 'configures driver' do
          r = line_regexp('driver = keystone.token.persistence.backends.sql.Token')
          expect(chef_run).to render_config_file(path).with_section_content('token', r)
        end

        it 'sets token expiration time' do
          r = line_regexp('expiration = 3600')
          expect(chef_run).to render_config_file(path).with_section_content('token', r)
        end

        it 'sets token hash algorithm' do
          r = line_regexp('hash_algorithm = md5')
          expect(chef_run).to render_config_file(path).with_section_content('token', r)
        end
      end

      describe '[policy] section' do
        it 'configures driver' do
          r = line_regexp('driver = keystone.policy.backends.sql.Policy')
          expect(chef_run).to render_config_file(path).with_section_content('policy', r)
        end
      end

      describe '[signing] section' do
        opts = {
          certfile: '/etc/keystone/ssl/certs/signing_cert.pem',
          keyfile: '/etc/keystone/ssl/private/signing_key.pem',
          ca_certs: '/etc/keystone/ssl/certs/ca.pem',
          key_size: '2048',
          valid_days: '3650',
          ca_password: nil
        }

        describe 'with pki' do
          it 'configures cert options' do
            opts.each do |key, val|
              r = line_regexp("#{key} = #{val}")
              expect(chef_run).to render_config_file(path).with_section_content('signing', r)
            end
          end
        end

        describe 'without pki' do
          before { node.set['openstack']['auth']['strategy'] = 'uuid' }
          it 'does not configure cert options' do
            opts.each do |key, val|
              expect(chef_run).not_to render_config_file(path).with_section_content('signing', /^#{key} = /)
            end
          end
        end
      end

      describe '[oslo_messaging_qpid] section' do
        it 'has defaults for oslo_messaging_qpid section' do
          node.set['openstack']['mq']['service_type'] = 'qpid'
          [/^amqp_durable_queues = false$/,
           /^amqp_auto_delete = false$/,
           /^rpc_conn_pool_size = 30$/,
           /^qpid_hostname = 127.0.0.1$/,
           /^qpid_port = 5672$/,
           /^qpid_username = guest$/,
           /^qpid_password = guest$/,
           /^qpid_sasl_mechanisms = $/,
           /^qpid_heartbeat = 60$/,
           /^qpid_protocol = tcp$/,
           /^qpid_tcp_nodelay = true$/,
           /^qpid_topology_version = 1$/
          ].each do |line|
            expect(chef_run).to render_config_file(path).with_section_content('oslo_messaging_qpid', line)
          end
        end
      end

      describe '[oslo_messaging_rabbit] section' do
        it 'has defaults for oslo_messaging_rabbit section' do
          [/^amqp_durable_queues = false$/,
           /^amqp_auto_delete = false$/,
           /^rpc_conn_pool_size = 30$/,
           /^rabbit_host = 127.0.0.1$/,
           /^rabbit_port = 5672$/,
           /^rabbit_use_ssl = false$/,
           /^rabbit_userid = guest$/,
           /^rabbit_password = guest$/,
           /^rabbit_virtual_host = \/$/
          ].each do |line|
            expect(chef_run).to render_config_file(path).with_section_content('oslo_messaging_rabbit', line)
          end
        end
        it 'has defaults for oslo_messaging_rabbit section with ha' do
          node.set['openstack']['mq']['identity']['rabbit']['ha'] = true
          [/^amqp_durable_queues = false$/,
           /^amqp_auto_delete = false$/,
           /^rpc_conn_pool_size = 30$/,
           /^rabbit_hosts = rabbit_servers_value$/,
           /^rabbit_use_ssl = false$/,
           /^rabbit_userid = guest$/,
           /^rabbit_password = guest$/,
           /^rabbit_virtual_host = \/$/,
           /^rabbit_ha_queues = true$/
          ].each do |line|
            expect(chef_run).to render_config_file(path).with_section_content('oslo_messaging_rabbit', line)
          end
        end
        it 'has komdefaults for oslo_messaging_rabbit section with ha' do
          node.set['openstack']['mq']['identity']['rabbit']['use_ssl'] = true
          node.set['openstack']['mq']['identity']['rabbit']['kombu_ssl_version'] = 'ssl_version'
          expect(chef_run).to render_config_file(path).with_section_content('oslo_messaging_rabbit', /^kombu_ssl_version = ssl_version$/)
        end
      end
    end

    describe 'default_catalog.templates' do
      let(:file) { '/etc/keystone/default_catalog.templates' }

      describe 'without templated backend' do
        it 'does not create' do
          expect(chef_run).not_to render_file(file)
        end
      end

      describe 'with templated backend' do
        before do
          node.set['openstack']['identity']['catalog']['backend'] = 'templated'
        end
        let(:template) { chef_run.template(file) }

        it 'creates' do
          expect(chef_run).to render_file(file)
        end

        it 'has proper owner' do
          expect(template.owner).to eq('keystone')
          expect(template.group).to eq('keystone')
        end

        it 'has proper modes' do
          expect(sprintf('%o', template.mode)).to eq('644')
        end

        it 'notifies keystone restart' do
          expect(template).to notify('service[keystone]').to(:restart)
        end
      end
    end

    describe 'db_sync' do
      let(:cmd) { 'keystone-manage db_sync' }

      it 'runs migrations' do
        expect(chef_run).to run_execute(cmd).with(
          user: 'keystone',
          group: 'keystone'
        )
      end

      it 'does not run migrations' do
        node.set['openstack']['db']['identity']['migrate'] = false
        expect(chef_run).not_to run_execute(cmd).with(
          user: 'keystone',
          group: 'keystone'
        )
      end
    end

    describe 'keystone-paste.ini as template' do

      let(:path) { '/etc/keystone/keystone-paste.ini' }
      let(:template) { chef_run.template(path) }

      it 'has proper owner' do
        expect(template.owner).to eq('keystone')
        expect(template.group).to eq('keystone')
      end

      it 'has proper modes' do
        expect(sprintf('%o', template.mode)).to eq('644')
      end
      it 'has default api pipeline value' do
        expect(chef_run).to render_file(path).with_content(/^pipeline = sizelimit url_normalize request_id build_auth_context token_auth admin_token_auth json_body ec2_extension user_crud_extension public_service$/)
        expect(chef_run).to render_file(path).with_content(/^pipeline = sizelimit url_normalize request_id build_auth_context token_auth admin_token_auth json_body ec2_extension s3_extension crud_extension admin_service$/)
        expect(chef_run).to render_file(path).with_content(/^pipeline = sizelimit url_normalize request_id build_auth_context token_auth admin_token_auth json_body ec2_extension_v3 s3_extension simple_cert_extension revoke_extension federation_extension oauth1_extension endpoint_filter_extension endpoint_policy_extension service_v3$/)
      end
      it 'template api pipeline set correct' do
        node.set['openstack']['identity']['pipeline']['public_api'] = 'public_service'
        node.set['openstack']['identity']['pipeline']['admin_api'] = 'admin_service'
        node.set['openstack']['identity']['pipeline']['api_v3'] = 'service_v3'
        expect(chef_run).to render_file(path).with_content(/^pipeline = public_service$/)
        expect(chef_run).to render_file(path).with_content(/^pipeline = admin_service$/)
        expect(chef_run).to render_file(path).with_content(/^pipeline = service_v3$/)
      end
      it 'template misc_paste array correctly' do
        node.set['openstack']['identity']['misc_paste'] = ['MISC1=OPTION1', 'MISC2=OPTION2']
        expect(chef_run).to render_file(path).with_content(
          /^MISC1=OPTION1$/)
        expect(chef_run).to render_file(path).with_content(
          /^MISC2=OPTION2$/)
      end
    end

    describe 'keystone-paste.ini as remote file' do
      before { node.set['openstack']['identity']['pastefile_url'] = 'http://server/mykeystone-paste.ini' }
      let(:remote_paste) { chef_run.remote_file('/etc/keystone/keystone-paste.ini') }

      it 'uses a remote file if pastefile_url is specified' do
        expect(chef_run).to create_remote_file_if_missing('/etc/keystone/keystone-paste.ini').with(
          source: 'http://server/mykeystone-paste.ini',
          user: 'keystone',
          group: 'keystone',
          mode: 00644)
        expect(remote_paste).to notify('service[keystone]').to(:restart)
      end
    end
  end
end
