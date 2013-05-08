require "spec_helper"

describe "horizon::db" do
  it "installs mysql packages" do
    @chef_run = converge

    expect(@chef_run).to include_recipe "mysql::client"
    expect(@chef_run).to include_recipe "mysql::ruby"
  end

  it "creates database and user" do
    ::Chef::Recipe.any_instance.should_receive(:db_create_with_user).
      with "identity", "keystone", "test-pass"

    converge
  end

  def converge
    ::Chef::Recipe.any_instance.stub(:db_password).with("keystone").
      and_return "test-pass"

    ::ChefSpec::ChefRunner.new(::UBUNTU_OPTS).converge "keystone::db"
  end
end
