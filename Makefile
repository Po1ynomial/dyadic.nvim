NVIM ?= nvim
MINI_TEST_PATH ?= deps/mini.test
export MINI_TEST_PATH

.PHONY: test deps

deps: $(MINI_TEST_PATH)

$(MINI_TEST_PATH):
	git clone --filter=blob:none https://github.com/nvim-mini/mini.test $(MINI_TEST_PATH)

# Run one file with: make test FILE=tests/test_render.lua
test: $(MINI_TEST_PATH)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run$(if $(FILE),_file('$(FILE)'),())"
