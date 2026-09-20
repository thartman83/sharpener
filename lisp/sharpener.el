;;; sharpener.el --- A porcelain for .NET development -*- lexical-binding: t; -*-

;; Author: Tom Hartman
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.0") (yasnippet "0.14.0"))
;; Keywords: languages, tools, dotnet, csharp
;; URL: https://github.com/thartman/sharpener

;;; Commentary:

;; sharpener is a porcelain for .NET development in Emacs, in the spirit
;; of magit: a set of composable, discoverable commands over the dotnet
;; toolchain, built on a shared discovery/inference substrate.
;;
;; It fills the gap left by CLI-wrapper packages like `sharper'
;; (solution/nuget management) and `dotnet.el' (build verbs): automatic
;; generation of new source files with sensible, accessibility-aware
;; boilerplate, in the spirit of Visual Studio's "Add New Item" dialog --
;; and, over time, a broader porcelain for project and solution work.
;;
;; This file is the package's loader and front door.  It defines nothing
;; of substance itself; it assembles the modules and (eventually) hosts
;; the top-level dispatch transient.  The layers below it:
;;
;;   sharpener-util      : project/solution discovery, namespace
;;                         inference, the dotnet command primitive.
;;                         No external dependencies.  Home of the
;;                         package-wide `defgroup'.
;;   sharpener-snippets  : yasnippet bridge -- snippet registration,
;;                         expansion into new files, the snippet-body API.
;;   sharpener-scaffold  : the file generators and `sharpener-new-file'
;;                         transient (the "Add New Item" picker).
;;
;; Entry points:
;;   `sharpener-new-file'          -- scaffold a source file (transient).
;;   `sharpener-register-snippets' -- register bundled templates with yas.

;;; Code:

(require 'sharpener-util)
(require 'sharpener-snippets)
(require 'sharpener-scaffold)

;; Future modules get required here as the porcelain grows, e.g.:
;;   (require 'sharpener-solution)   ; sln add/remove/list verbs
;;   (require 'sharpener-package)    ; nuget add/restore/search
;;   (require 'sharpener-watch)      ; supervised `dotnet watch'
;;   (require 'sharpener-dispatch)   ; the top-level magit-style menu

;; Register bundled snippets once yasnippet is available.
(sharpener-register-snippets)

(provide 'sharpener)
;;; sharpener.el ends here
