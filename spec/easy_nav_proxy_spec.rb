# frozen_string_literal: true

RSpec.describe EasyNavProxy do
  it "allows keys to be accessed by symbol, string, or method call" do
    hash = {foo: "bar", baz: 5, qux: {"quux" => 10}}
    enav = hash.easynav

    expect(enav["foo"]).to eq("bar")
    expect(enav[:baz]).to eq(5)
    expect(enav.qux).to eq({"quux" => 10})
    expect(enav.qux.quux).to eq(10)

    array = [10,20,30]
    enav = array.easynav

    expect(enav[0]).to eq(10)
    expect(enav[1]).to eq(20)
    expect(enav[-1]).to eq(30)
    expect(enav.last).to eq(30)
  end

  it "supports hash destructuring" do
    hash = {foo: "bar", baz: 5, qux: {"quux" => 10}}
    enav = hash.easynav
    enav => {foo: foo, baz: baz, qux: qux}
    expect(foo).to eq("bar")
    expect(baz).to eq(5)
    expect(qux).to eq({"quux" => 10})
  end
end
