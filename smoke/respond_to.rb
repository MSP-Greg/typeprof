def foo(n)
  if n.respond_to?(:times)
    n.times {|_| n = :sym }
  elsif n.respond_to?(:+)
    n + "foo"
  else
    n & false
  end
end


foo(1)
foo("str")
foo(true)

# no error expected

__END__
# Classes
class Object
  def foo : (Integer | String | true) -> (Integer | String | bool)
end
