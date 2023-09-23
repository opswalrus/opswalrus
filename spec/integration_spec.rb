# frozen_string_literal: true

RSpec.describe OpsWalrus do
  before :all do
    $app = app = OpsWalrus::App.new(__dir__)
  end

  it "has a version number" do
    expect(Opswalrus::VERSION).not_to be nil
  end

  it "updates the bundle" do
    expect($app.bundle_update).to eq(true)
  end

  it "bootstraps the host" do
    expect($app.bootstrap).to eq(true)
  end

  it "runs whoami on the remote host" do
    expect($app.run("opswalrus/core whoami")).to eq("vagrant")
  end
end
