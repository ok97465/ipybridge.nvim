local MockVim = {}

function MockVim.new()
  local notifications = {}
  local scheduled = {}

  local function run_scheduled(fn)
    table.insert(scheduled, fn)
    fn()
  end

  local vim_mock = {
    notify = function(msg, level)
      table.insert(notifications, { message = msg, level = level })
    end,
    schedule = run_scheduled,
    log = {
      levels = {
        WARN = 'WARN',
      },
    },
  }

  return {
    vim = vim_mock,
    notifications = notifications,
    run_scheduled = run_scheduled,
  }
end

return MockVim
