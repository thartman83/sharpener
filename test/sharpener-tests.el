;;; sharpener-tests.el --- Aggregate loader for all sharpener suites -*- lexical-binding: t; -*-

;;; Commentary:

;; Convenience loader that pulls in every per-module test suite, so a
;; single `-l test/sharpener-tests.el' runs the whole thing.  The Makefile
;; targets load this; to run one module's tests in isolation, load that
;; file directly instead (e.g. test/sharpener-util-tests.el).

;;; Code:

(require 'sharpener-util-tests)
(require 'sharpener-snippets-tests)
(require 'sharpener-scaffold-tests)
(require 'sharpener-registration-tests)

(provide 'sharpener-tests)
;;; sharpener-tests.el ends here
