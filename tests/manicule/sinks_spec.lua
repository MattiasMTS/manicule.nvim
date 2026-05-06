local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup()
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

describe("manicule sink helpers", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("formats comments as an agent-ready markdown review", function()
    local path = H.write_project_file(ctx, "src/sinks.lua", {
      "local value = 1",
      "return value",
    })
    local record = {
      body = "first line\nsecond line",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 1, 0 } },
      uri = "file://" .. path,
    }

    local text = require("manicule.sinks.helpers").format_markdown_review({ record })

    assert.is_truthy(text:find("Manicule review (1 comment):", 1, true))
    assert.is_truthy(text:find("## src/sinks.lua:1-2", 1, true))
    assert.is_truthy(text:find("first line\nsecond line", 1, true))
  end)

  it("registers builtin integrations from sink config", function()
    require("manicule.sinks")._reset()
    local bin = H.fake_cmux(ctx)
    require("manicule.sinks").setup({
      clipboard = true,
      cmux = {
        enabled = true,
        command = bin,
        workspace_id = "workspace-1",
      },
    })

    local names = require("manicule.sinks").list()
    assert.are.same({ "clipboard", "cmux" }, names)
    assert.are.equal("sink", require("manicule.sinks").get("clipboard").type)
    assert.are.equal("integration", require("manicule.sinks").get("cmux").type)
  end)

  it("keeps auto cmux disabled outside cmux", function()
    require("manicule.sinks")._reset()
    require("manicule.sinks").setup({
      clipboard = false,
      cmux = {
        enabled = "auto",
        command = ctx.state .. "/missing-cmux",
        workspace_id = "workspace-1",
      },
    })

    assert.are.same({}, require("manicule.sinks").list())
  end)

  it("discovers a generic-titled split pane by reading the agent screen", function()
    local bin = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "manicule.nvim" },
        { id = "surface-agent", ref = "surface:2", title = "manicule.nvim" },
      },
      tree = {
        'surface:1 [terminal] "manicule.nvim" tty=ttys001 here',
        'surface:2 [terminal] "manicule.nvim" tty=ttys002',
      },
      screens = {
        ["surface:2"] = "OpenAI Codex\nContext 0 tokens\nReady",
      },
    })

    local surfaces, err = require("manicule.sinks.cmux").list_agent_surfaces({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      cache = false,
      agent_state_dir = ctx.state,
    })

    assert.is_nil(err)
    assert.are.equal(1, #surfaces)
    assert.are.equal("surface:2", surfaces[1].ref)
    assert.are.equal("Codex", surfaces[1].agent)
    assert.are.equal("screen", surfaces[1].detected_by)
  end)

  it("reports thrown validate and send callbacks as dispatch failures", function()
    local sinks = require("manicule.sinks")
    sinks.register({
      name = "bad-validate",
      send = function(_, _, cb)
        cb(true)
      end,
      validate = function()
        error("validate exploded")
      end,
    })
    sinks.register({
      name = "bad-send",
      send = function()
        error("send exploded")
      end,
    })

    local validate_result
    sinks.dispatch("bad-validate", {}, {}, function(ok, err)
      validate_result = { ok = ok, err = err }
    end)
    assert.is_false(validate_result.ok)
    assert.is_truthy(validate_result.err:find("validate failed", 1, true))

    local send_result
    sinks.dispatch("bad-send", {}, {}, function(ok, err)
      send_result = { ok = ok, err = err }
    end)
    assert.is_false(send_result.ok)
    assert.is_truthy(send_result.err:find("send failed", 1, true))
  end)
end)
