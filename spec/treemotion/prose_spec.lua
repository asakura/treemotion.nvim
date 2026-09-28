--- Direct unit tests for `_commands.motion.prose`'s word splitting --
--- `M.split_words`, `M.words` -- isolated from the motion machinery that
--- consumes them. See `treemotion_spec.lua` for the end-to-end prose and
--- backtick-identifier motion tests.

local prose = require("treemotion._commands.motion.prose")

describe("prose.split_words", function()
    it("splits on blanks and drops them", function()
        assert.same(
            { { text = "hello", offset = 1 }, { text = "world", offset = 8 } },
            prose.split_words("hello  world")
        )
    end)

    it("groups a run of punctuation into one word", function()
        assert.same({ { text = "wait", offset = 1 }, { text = "?!", offset = 5 } }, prose.split_words("wait?!"))
    end)

    it("keeps -, :, / and _ inside a word for the delimiter pass to decide", function()
        assert.same({ { text = "github:NixOS/nix-pkgs_x", offset = 1 } }, prose.split_words("github:NixOS/nix-pkgs_x"))
    end)

    it("returns nothing for all-blank text", function()
        assert.same({}, prose.split_words("   "))
    end)
end)

describe("prose.words", function()
    it("flags a single-word backtick span as an identifier and drops the backticks", function()
        assert.same({
            { text = "see", offset = 1 },
            { text = "fooBar", offset = 6, is_identifier = true },
            { text = "here", offset = 14 },
        }, prose.words("see `fooBar` here", true, 16))
    end)

    it("leaves a multi-word backtick span as ordinary prose", function()
        assert.same({
            { text = "`", offset = 1 },
            { text = "foo", offset = 2 },
            { text = "bar", offset = 6 },
            { text = "`", offset = 9 },
        }, prose.words("`foo bar`", true, 16))
    end)

    it("treats backticks as ordinary punctuation when backtick_identifiers is off", function()
        assert.same({
            { text = "`", offset = 1 },
            { text = "fooBar", offset = 2 },
            { text = "`", offset = 8 },
        }, prose.words("`fooBar`", false, 16))
    end)

    it("merges base64 padding back into the hash before it", function()
        assert.same(
            { { text = "see", offset = 1 }, { text = "A8YgPkQ3xZ7rT2mN9sLwVbE1=", offset = 5 } },
            prose.words("see A8YgPkQ3xZ7rT2mN9sLwVbE1=", true, 16)
        )
    end)

    it("keeps a trailing = separate when the word before it isn't hash-shaped", function()
        assert.same({ { text = "x", offset = 1 }, { text = "=", offset = 2 } }, prose.words("x=", true, 16))
    end)
end)
