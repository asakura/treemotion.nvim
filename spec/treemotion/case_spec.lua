--- Direct unit tests for `_commands.motion.case`'s pure string helpers --
--- `M.split`, `M.looks_like_hash` -- isolated from the motion machinery
--- that consumes them. See `treemotion_spec.lua` for the end-to-end
--- camelCase/PascalCase/opaque-token motion tests.

local case = require("treemotion._commands.motion.case")

describe("case.split", function()
    it("splits camelCase before each uppercase letter", function()
        assert.same({ "foo", "Bar", "Baz" }, case.split("fooBarBaz", true, true))
    end)

    it("keeps an acronym together and splits before the word after it", function()
        assert.same({ "XML", "Http", "Request" }, case.split("XMLHttpRequest", true, true))
    end)

    it("splits after a digit", function()
        assert.same({ "sha256", "Sum" }, case.split("sha256Sum", true, true))
    end)

    it("only consults camel_case for a lowercase-leading identifier", function()
        assert.same({ "fooBar" }, case.split("fooBar", false, true))
        assert.same({ "Foo", "Bar" }, case.split("FooBar", false, true))
    end)

    it("only consults pascal_case for an uppercase-leading identifier", function()
        assert.same({ "FooBar" }, case.split("FooBar", true, false))
        assert.same({ "foo", "Bar" }, case.split("fooBar", true, false))
    end)

    it("leaves text with no case boundary whole", function()
        assert.same({ "foo" }, case.split("foo", true, true))
        assert.same({ "FOO" }, case.split("FOO", true, true))
    end)
end)

describe("case.looks_like_hash", function()
    it("accepts a long hex digest", function()
        assert.is_true(case.looks_like_hash("0123456789abcdef0123456789abcdef", 16))
    end)

    it("accepts base64 with mixed case, a digit and trailing padding", function()
        assert.is_true(case.looks_like_hash("A8YgPkQ3xZ7rT2mN9sLwVbE1=", 16))
    end)

    it("rejects anything shorter than min_length after stripping padding", function()
        assert.is_false(case.looks_like_hash("abcdef0123==", 16))
    end)

    it("rejects a long camelCase identifier with no digit", function()
        assert.is_false(case.looks_like_hash("handleSubmitButtonClick", 16))
    end)

    it("rejects base64-shaped text missing an uppercase or lowercase letter", function()
        assert.is_false(case.looks_like_hash("ABCDEFGHIJKLMNOP1234", 16))
    end)
end)
