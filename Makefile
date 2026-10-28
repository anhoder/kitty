ifdef V
	VVAL=--verbose
endif
ifdef VERBOSE
	VVAL=--verbose
endif

ifdef FAIL_WARN
export FAIL_WARN
endif

# The slang shader compiler. Used when building the shaders and copied into the
# app bundle, since a frozen kitty only ever looks for slangc next to its own
# launcher (see kitty/constants.py), never in PATH or SLANGC.
SLANGC ?= $(HOME)/.local/slang/bin/slangc

all:
	python3 setup.py $(VVAL)

test:
	python3 setup.py $(VVAL) test

clean:
	python3 setup.py $(VVAL) clean

# A debug build
debug:
	python3 setup.py build $(VVAL) --debug

debug-event-loop:
	python3 setup.py build $(VVAL) --debug --extra-logging=event-loop

# Build with the ASAN and UBSAN sanitizers
asan:
	python3 setup.py build $(VVAL) --debug --sanitize

profile:
	python3 setup.py build $(VVAL) --profile

app:
	python3 setup.py kitty.app $(VVAL)

# Build a standalone macOS app bundle using the same packaging path as CI.
# Set SLANGC when slangc is installed somewhere other than ~/.local/slang/bin.
macos-app: FORCE
	@test "$$(uname -s)" = Darwin || { echo 'macos-app requires macOS' >&2; exit 1; }
	SLANGC="$(SLANGC)" python3 setup.py build --verbose $(VVAL)
	SLANGC="$(SLANGC)" $(MAKE) FAIL_WARN=1 docs
	SLANGC="$(SLANGC)" python3 setup.py kitty.app --update-check-interval=0 $(VVAL)
	@set -e; \
	test -x "$(SLANGC)" || { echo "slangc not found at $(SLANGC); install shader-slang or set SLANGC" >&2; exit 1; }; \
	slang_lib=$$(cd "$$(dirname "$(SLANGC)")/../lib" && pwd); \
	for f in "$$slang_lib"/libslang-compiler.0.*.dylib "$$slang_lib"/libslang-glslang-*.dylib "$$slang_lib"/libslang-glsl-module-*.dylib; do \
		test -f "$$f" || { echo "missing slang runtime library: $$f" >&2; exit 1; }; \
	done; \
	cp -f "$(SLANGC)" kitty.app/Contents/MacOS/slangc; \
	cp -f "$$slang_lib"/libslang-compiler.0.*.dylib "$$slang_lib"/libslang-glslang-*.dylib "$$slang_lib"/libslang-glsl-module-*.dylib kitty.app/Contents/MacOS/; \
	echo "Bundled slangc $$(kitty.app/Contents/MacOS/slangc -v 2>&1) into kitty.app"
	kitty.app/Contents/MacOS/kitty +runpy "from kitty.constants import *; print(kitty_exe())"
	kitty.app/Contents/MacOS/kitty +runpy "import subprocess; from kitty.constants import slangc; print('runtime slangc:', *slangc()); print(subprocess.check_output(list(slangc()) + ['-v']).decode().strip())"
	codesign --force --deep --sign - kitty.app

linux-package: FORCE
	rm -rf linux-package
	python3 setup.py linux-package

FORCE:

man:
	$(MAKE) -C docs man

html:
	$(MAKE) -C docs html

dirhtml:
	$(MAKE) -C docs dirhtml

linkcheck:
	$(MAKE) -C docs linkcheck

website:
	./publish.py --only website

docs: man html


develop-docs:
	$(MAKE) -C docs develop-docs


prepare-for-cross-compile: clean all
	python3 setup.py $(VVAL) clean --clean-for-cross-compile

cross-compile:
	python3 setup.py linux-package --skip-code-generation

