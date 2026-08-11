--- Entrypoint for the `:checkhealth` CI workflow, which runs plain `nvim -u`
--- without going through Nix at all, so `mega.cmdparse`/`mega.logging` aren't
--- on `package.path` the way they are for busted-driven runs. Fetch them
--- first, then defer to the same bootstrapping `spec/minimal_init.lua` does
--- for tests.

dofile("spec/bootstrap_dependencies.lua")
dofile("spec/minimal_init.lua")
