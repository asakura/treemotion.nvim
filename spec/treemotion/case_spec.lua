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

    it("keeps an acronym with a one-letter suffix together", function()
        assert.same({ "CIDRv4" }, case.split("CIDRv4", true, true))
        assert.same({ "IPv4" }, case.split("IPv4", true, true))
        assert.same({ "URLs" }, case.split("URLs", true, true))
        assert.same({ "IDs", "List" }, case.split("IDsList", true, true))
        assert.same({ "get", "URLs", "For" }, case.split("getURLsFor", true, true))
        assert.same({ "TCPv6", "Socket" }, case.split("TCPv6Socket", true, true))
    end)

    it("still splits an acronym from a longer word after it", function()
        assert.same({ "UI", "Kit" }, case.split("UIKit", true, true))
        assert.same({ "HTTP", "Server" }, case.split("HTTPServer", true, true))
    end)

    it("keeps a non-ASCII acronym with a one-letter suffix together", function()
        assert.same({ "ÉTATs" }, case.split("ÉTATs", true, true))
        assert.same({ "ÉTAT", "Bar" }, case.split("ÉTATBar", true, true))
        assert.same({ "ÉT", "Ats" }, case.split("ÉTAts", true, true))
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

    it("splits before an accented or non-Latin uppercase letter", function()
        assert.same({ "café", "Bar" }, case.split("caféBar", true, true))
        assert.same({ "foo", "État" }, case.split("fooÉtat", true, true))
        assert.same({ "Ωmega", "Δelta" }, case.split("ΩmegaΔelta", true, true))
    end)

    it("reads an accented first letter's case", function()
        assert.same({ "Été", "Bar" }, case.split("ÉtéBar", false, true))
        assert.same({ "ÉtéBar" }, case.split("ÉtéBar", true, false))
    end)

    it("doesn't split after a caseless character", function()
        assert.same({ "日本語Text" }, case.split("日本語Text", true, true))
        assert.same({ "a😀B" }, case.split("a😀B", true, true))
        assert.same({ "a\255B" }, case.split("a\255B", true, true))
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
