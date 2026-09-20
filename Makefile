# sharpener -- Makefile for linting, byte-compilation, and testing.
#
# Local targets run against whatever Emacs and dotnet SDK are on PATH.
# Container targets run the suite inside a clean Docker image to surface
# hidden package dependencies (a require you forgot because your live
# config already loaded it) and environment assumptions.
#
# Layout: source lives in lisp/, tests in test/. Both go on the batch
# load-path so requires resolve by feature name.
#
# Usage:
#   make test              # full suite (needs emacs + dotnet)
#   make test-fast         # skip :dotnet-tagged integration tests
#   make test-FILE         # run one module's suite, e.g. make test-util
#   make compile           # byte-compile with warnings as errors
#   make lint              # compile + checkdoc
#   make clean             # remove .elc artifacts
#   make container-test        # full suite in a clean Arch container
#   make container-test-fast   # fast suite in a clean Arch container
#   make container-shell       # drop into the container for poking around
#   make container-test-distro DISTRO=ubuntu   # other distro scaffold

EMACS      ?= emacs
PACKAGE     = sharpener

# Directories.
LISP_DIR    = lisp
TEST_DIR    = test

# Source files, in load order: util first (everything requires it),
# snippets and scaffold next, the loader last (it requires the rest).
SRC = $(LISP_DIR)/sharpener-util.el \
      $(LISP_DIR)/sharpener-snippets.el \
      $(LISP_DIR)/sharpener-scaffold.el \
      $(LISP_DIR)/sharpener.el

# Test suites. The aggregate loader pulls in the per-module suites; the
# common harness is required transitively, not run on its own.
TESTS       = $(TEST_DIR)/sharpener-tests.el
ELC         = $(SRC:.el=.elc)

# Isolated package dir for test dependencies (yasnippet), so provisioning
# never touches a real ~/.emacs.d. Overridable for CI.
SHARPENER_TEST_PKGDIR ?= $(CURDIR)/.sharpener-pkg
export SHARPENER_TEST_PKGDIR

# Batch Emacs with the source and test dirs on the load-path, and the
# test package-init loader sourced first so installed deps (yasnippet)
# are available. test-init.el is a no-op if deps were never installed,
# so the fast path still runs without provisioning.
BATCH       = $(EMACS) -Q -batch \
                -L $(LISP_DIR) -L $(TEST_DIR) \
                -l $(TEST_DIR)/test-init.el

# Container settings. DISTRO selects the Dockerfile under docker/.
DISTRO     ?= arch
IMAGE       = sharpener-test-$(DISTRO)
DOCKERFILE  = docker/Dockerfile.$(DISTRO)

.PHONY: all deps test test-full test-fast test-util test-snippets test-scaffold \
        compile lint clean help \
        container-build container-test container-test-fast \
        container-shell container-test-distro container-clean

all: test

help:
	@echo "Local:     test  test-fast  compile  lint  clean"
	@echo "Per-module: test-util  test-snippets  test-scaffold"
	@echo "Container: container-test  container-test-fast  container-shell"
	@echo "           container-test-distro DISTRO=<name>"

## ---- Dependencies ---------------------------------------------------

# Install third-party test deps (yasnippet) into the isolated pkg dir.
# Run once; the marker dir's existence is what test-init.el keys on.
# Re-run to refresh. `make test-full' below chains this automatically.
deps:
	$(EMACS) -Q -batch -l $(TEST_DIR)/install-deps.el

## ---- Local targets --------------------------------------------------

# Full suite. Loads source (not .elc) so you always test current code.
# Does NOT install deps; run `make deps' once first, or use `test-full'.
test:
	$(BATCH) -l ert -l $(TESTS) -f ert-run-tests-batch-and-exit

# Full suite WITH dependency provisioning -- the "just make it pass"
# target. Installs yasnippet if absent, then runs everything.
test-full: deps test

# Fast suite: everything except the dotnet-fixture integration tests.
test-fast:
	$(BATCH) -l ert -l $(TESTS) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag :dotnet))))'

# Per-module suites, for tight iteration on one layer. Each loads only
# that module's tests (which pull in the common harness themselves).
test-util:
	$(BATCH) -l ert -l $(TEST_DIR)/sharpener-util-tests.el \
	  -f ert-run-tests-batch-and-exit

test-snippets:
	$(BATCH) -l ert -l $(TEST_DIR)/sharpener-snippets-tests.el \
	  -f ert-run-tests-batch-and-exit

test-scaffold:
	$(BATCH) -l ert -l $(TEST_DIR)/sharpener-scaffold-tests.el \
	  -f ert-run-tests-batch-and-exit

test-registration:
	$(BATCH) -l ert -l $(TEST_DIR)/sharpener-registration-tests.el \
	  -f ert-run-tests-batch-and-exit

# Byte-compile with warnings promoted to errors -- this is what surfaces
# undeclared functions, unused lexicals, and missing requires. Run in a
# clean process so a stale .elc or a loaded config can't mask a problem.
compile: clean
	$(BATCH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

# checkdoc on every source file, plus the compile check.
lint: compile
	$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(patsubst %,"%",$(SRC)))) (checkdoc-file f)))'

clean:
	rm -f $(ELC) $(TEST_DIR)/*.elc

## ---- Container targets ----------------------------------------------

container-build:
	docker build -f $(DOCKERFILE) -t $(IMAGE) .

# Run the full suite in a freshly built clean image. The build itself is
# part of the test: if the Dockerfile's package list is missing something
# the suite needs, it fails here in a way your live machine never would.
container-test: container-build
	docker run --rm $(IMAGE) make test

container-test-fast: container-build
	docker run --rm $(IMAGE) make test-fast

# Interactive shell in the container for debugging a failure in situ.
container-shell: container-build
	docker run --rm -it $(IMAGE) bash

# Convenience wrapper so `make container-test-distro DISTRO=ubuntu` reads
# naturally; just re-enters with the DISTRO-specific image/dockerfile.
container-test-distro:
	$(MAKE) container-test DISTRO=$(DISTRO)

container-clean:
	-docker rmi $(IMAGE)
