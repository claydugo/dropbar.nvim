return setmetatable({
  bar = nil, ---@module 'dropbar.utils.bar'
  compat = nil, ---@module 'dropbar.utils.compat'
  menu = nil, ---@module 'dropbar.utils.menu'
  source = nil, ---@module 'dropbar.utils.source'
}, {
  __index = function(_, key)
    return require('dropbar.utils.' .. key)
  end,
})
