ifdef V
	VVAL=--verbose
endif
ifdef VERBOSE
	VVAL=--verbose
endif

ifdef FAIL_WARN
export FAIL_WARN
endif

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
	SLANGC="$${SLANGC:-$$HOME/.local/slang/bin/slangc}" python3 setup.py build --verbose $(VVAL)
	SLANGC="$${SLANGC:-$$HOME/.local/slang/bin/slangc}" $(MAKE) FAIL_WARN=1 docs
	SLANGC="$${SLANGC:-$$HOME/.local/slang/bin/slangc}" python3 setup.py kitty.app --update-check-interval=0 $(VVAL)
	kitty.app/Contents/MacOS/kitty +runpy "from kitty.constants import *; print(kitty_exe())"
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

