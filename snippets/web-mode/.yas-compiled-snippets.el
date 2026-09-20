;;; "Compiled" snippets and support files for `web-mode'  -*- lexical-binding:t -*-
;;; Snippet definitions:
;;;
(yas-define-snippets 'web-mode
		     '(("page"
			"@page\n@model ${1:`(sharpener-yas--namespace-plain)`}.${2:`(sharpener-yas--type-name)`}Model\n@{\n    ViewData[\"Title\"] = \"${2:$(sharpener-yas--titleize yas-text)}\";\n}\n\n<h1>$0</h1>"
			"razor-page" nil nil nil
			"/home/thartman/projects/sharpener/snippets/web-mode/razor-page"
			nil nil)))


;;; Do not edit! File generated at Mon Aug 24 19:23:29 2026
