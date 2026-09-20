;;; "Compiled" snippets and support files for `csharp-ts-mode'  -*- lexical-binding:t -*-
;;; Snippet definitions:
;;;
(yas-define-snippets 'csharp-ts-mode
		     '(("pagemodel"
			"using Microsoft.AspNetCore.Mvc.RazorPages;\n\n`(sharpener-yas--namespace-open)`public class ${1:`(sharpener-yas--type-name)`}Model : PageModel\n{\n    public void OnGet()\n    {\n        $0\n    }\n}`(sharpener-yas--namespace-close)`"
			"razor-page-model" nil nil nil
			"/home/thartman/projects/sharpener/snippets/csharp-ts-mode/razor-page-model"
			nil nil)
		       ("interface"
			"`(sharpener-yas--namespace-open)`public interface ${1:`(sharpener-yas--type-name \"I\")`}\n{\n    $0\n}`(sharpener-yas--namespace-close)`"
			"interface" nil nil nil
			"/home/thartman/projects/sharpener/snippets/csharp-ts-mode/interface"
			nil nil)
		       ("class"
			"`(sharpener-yas--namespace-open)`public class ${1:`(sharpener-yas--type-name)`}\n{\n    $0\n}`(sharpener-yas--namespace-close)`"
			"class" nil nil nil
			"/home/thartman/projects/sharpener/snippets/csharp-ts-mode/class"
			nil nil)))


;;; Do not edit! File generated at Mon Aug 24 19:23:29 2026
