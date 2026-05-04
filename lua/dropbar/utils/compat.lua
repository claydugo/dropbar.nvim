local M = {}

-- Neovim PR #35610 (released in 0.13) removed `BufModifiedSet` in favor of
-- `OptionSet` with pattern `modified`. Detect once at load time so configs
-- and call sites can keep using `BufModifiedSet` on either version.
local has_buf_modified_set = vim.fn.exists('##BufModifiedSet') == 1

---Create autocmd(s) for a list of events, transparently translating
---`BufModifiedSet` to `OptionSet` with pattern `modified` on neovim
---builds where `BufModifiedSet` was removed (neovim/neovim#35610).
---
---On the translated path the helper synthesizes `BufModifiedSet`
---semantics for the caller:
--- * `args.buf` is rewritten to the affected buffer (`OptionSet` itself
---   reports `0`); the affected buffer is recovered from `curbuf`, which
---   `aucmd_defer_modified` switches to before firing the deferred event.
--- * `buffer = ...` scoping is preserved by filtering inside the callback,
---   since `nvim_create_autocmd` disallows `pattern` + `buffer` together.
--- * `once = true` is honored across both halves of a split registration:
---   when the events list mixes `BufModifiedSet` with other events, the
---   underlying two autocmds share a single lifecycle and the first to
---   match deletes its sibling. The same path also fixes the
---   buffer-filtered case, where the engine would otherwise consume
---   `once` on the first non-target buffer's modified change.
---
---Constraints on non-function callbacks: `command = ...` strings cannot
---be wrapped, so combining a non-function callback with `buffer = ...`
---scoping or with `once = true` (when the events list spans
---`BufModifiedSet` plus others) raises an error rather than silently
---registering the wrong thing.
---
---Returns a single autocmd id when one autocmd is created, or a list of
---ids when the events had to be split. Pair with `M.del_autocmd` to free
---the returned value uniformly.
---@param events string|string[]
---@param opts vim.api.keyset.create_autocmd
---@return integer|integer[]
function M.create_autocmd(events, opts)
  if type(events) == 'string' then
    events = { events }
  end

  if has_buf_modified_set then
    return vim.api.nvim_create_autocmd(events, opts)
  end

  local rest, has_bms = {}, false
  for _, e in ipairs(events) do
    if e == 'BufModifiedSet' then
      has_bms = true
    else
      table.insert(rest, e)
    end
  end

  if not has_bms then
    -- No translation needed; defer entirely to the API to preserve all
    -- of its semantics, including its error behavior on empty input.
    return vim.api.nvim_create_autocmd(events, opts)
  end

  local target_buf = opts.buffer
  if target_buf == 0 then
    target_buf = vim.api.nvim_get_current_buf()
  end

  local will_split = not vim.tbl_isempty(rest)
  local needs_buffer_filter = target_buf ~= nil
  local once = opts.once == true
  -- We have to manage `once` ourselves whenever the engine can't see the
  -- whole picture: when scoping is hidden behind our buffer filter, or
  -- when the union of events spans two underlying autocmds.
  local manual_once = once and (will_split or needs_buffer_filter)

  local cb = opts.callback
  if type(cb) ~= 'function' then
    -- `command = ...` strings cannot be wrapped, so we can't synthesize
    -- a buffer filter or cross-half once around them. Name the offending
    -- field explicitly so the caller knows what to swap.
    local got = opts.command ~= nil and '`command = ...`'
      or ('`callback` of type ' .. type(cb))
    if needs_buffer_filter then
      error(
        'dropbar.utils.compat: buffer-scoped translation of '
          .. 'BufModifiedSet requires `callback` to be a Lua function; '
          .. 'got '
          .. got
      )
    end
    if manual_once then
      error(
        'dropbar.utils.compat: combining BufModifiedSet with other '
          .. 'events and `once = true` requires `callback` to be a Lua '
          .. 'function; got '
          .. got
      )
    end
  end

  local rest_id, os_id
  local function consume_once()
    if rest_id then
      pcall(vim.api.nvim_del_autocmd, rest_id)
      rest_id = nil
    end
    if os_id then
      pcall(vim.api.nvim_del_autocmd, os_id)
      os_id = nil
    end
  end

  if will_split then
    local rest_opts = vim.tbl_extend('force', {}, opts)
    if manual_once then
      rest_opts.once = nil
      rest_opts.callback = function(args)
        consume_once()
        return cb(args)
      end
    end
    rest_id = vim.api.nvim_create_autocmd(rest, rest_opts)
  end

  do
    local os_opts = vim.tbl_extend('force', {}, opts)
    os_opts.buffer = nil
    os_opts.pattern = 'modified'
    if manual_once then
      os_opts.once = nil
    end

    if type(cb) == 'function' then
      os_opts.callback = function(args)
        local cur = vim.api.nvim_get_current_buf()
        if needs_buffer_filter and cur ~= target_buf then
          return
        end
        if manual_once then
          consume_once()
        end
        return cb(vim.tbl_extend('force', args, { buf = cur }))
      end
    end
    os_id = vim.api.nvim_create_autocmd('OptionSet', os_opts)
  end

  if rest_id and os_id then
    return { rest_id, os_id }
  end
  return rest_id or os_id
end

---Delete an autocmd or list of autocmds returned by `M.create_autocmd`.
---Tolerates ids that have already self-deleted (e.g. via `once = true`
---on the translated path), so callers can store the returned id and
---unconditionally clean it up on detach without racing manual once.
---@param id integer|integer[]
function M.del_autocmd(id)
  if type(id) == 'table' then
    for _, i in ipairs(id) do
      pcall(vim.api.nvim_del_autocmd, i)
    end
  else
    pcall(vim.api.nvim_del_autocmd, id)
  end
end

return M
