local expect = require("mini.test").expect

local M = {}

setmetatable(M, {
  __call = function(_, value, message)
    return assert(value, message)
  end,
})

M.are = {
  equal = expect.equality,
  same = expect.equality,
}

M.are_not = {
  equal = expect.no_equality,
  same = expect.no_equality,
}

function M.is_nil(value)
  return expect.equality(nil, value)
end

function M.is_true(value)
  return expect.equality(true, value)
end

function M.is_false(value)
  return expect.equality(false, value)
end

function M.is_truthy(value)
  return expect.no_equality(nil, value)
end

return M
