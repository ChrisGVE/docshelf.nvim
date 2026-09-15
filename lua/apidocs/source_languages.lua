-- Which language each devdocs source belongs to. Hand-maintained: this table
-- is the source of truth, not a detector.
--
-- Keyed by source family (the slug before "~": python~3.14 -> python).
--   language  the source documents the language itself (python, lua, rust)
--   package   a library or framework of that language (numpy, tokio)
--   tool      a program or service; no language link (git, redis, docker)
-- A language name is a key of linguist_languages.lua.
--
-- Seeded 2026-09-15 from each source's GitHub repository language and a name
-- match against Linguist, then corrected by hand: a repository's language is
-- what the program is written in (git: C), not what its documentation is for.
-- Families devdocs adds later are simply absent, and so unlinked.
return {
  ["angular"] = { kind = "package", language = "TypeScript" }, -- Angular
  ["angularjs"] = { kind = "package", language = "JavaScript" }, -- Angular.js
  ["ansible"] = { kind = "tool", language = nil }, -- Ansible
  ["apache_http_server"] = { kind = "tool", language = nil }, -- Apache HTTP Server
  ["apache_pig"] = { kind = "package", language = "PigLatin" }, -- Apache Pig
  ["astro"] = { kind = "language", language = "Astro" }, -- Astro
  ["async"] = { kind = "package", language = "JavaScript" }, -- Async
  ["axios"] = { kind = "package", language = "JavaScript" }, -- Axios
  ["babel"] = { kind = "package", language = "TypeScript" }, -- Babel
  ["backbone"] = { kind = "package", language = "JavaScript" }, -- Backbone.js
  ["bash"] = { kind = "language", language = "Shell" }, -- Bash
  ["bazel"] = { kind = "tool", language = nil }, -- Bazel
  ["bluebird"] = { kind = "package", language = "JavaScript" }, -- Bluebird
  ["bootstrap"] = { kind = "package", language = "CSS" }, -- Bootstrap
  ["bottle"] = { kind = "package", language = "Python" }, -- Bottle
  ["bower"] = { kind = "tool", language = nil }, -- Bower
  ["browser_support_tables"] = { kind = "tool", language = nil }, -- Support Tables
  ["bun"] = { kind = "package", language = "JavaScript" }, -- Bun
  ["c"] = { kind = "language", language = "C" }, -- C
  ["cakephp"] = { kind = "package", language = "PHP" }, -- CakePHP
  ["celery"] = { kind = "package", language = "Python" }, -- Celery
  ["chai"] = { kind = "package", language = "JavaScript" }, -- Chai
  ["chef"] = { kind = "tool", language = nil }, -- Chef
  ["click"] = { kind = "package", language = "Python" }, -- click
  ["clojure"] = { kind = "language", language = "Clojure" }, -- Clojure
  ["cmake"] = { kind = "tool", language = nil }, -- CMake
  ["codeception"] = { kind = "package", language = "PHP" }, -- Codeception
  ["codeceptjs"] = { kind = "package", language = "JavaScript" }, -- CodeceptJS
  ["codeigniter"] = { kind = "package", language = "PHP" }, -- CodeIgniter
  ["coffeescript"] = { kind = "language", language = "CoffeeScript" }, -- CoffeeScript
  ["coldfusion"] = { kind = "language", language = "ColdFusion" }, -- ColdFusion
  ["composer"] = { kind = "package", language = "PHP" }, -- Composer
  ["cordova"] = { kind = "package", language = "JavaScript" }, -- Cordova
  ["couchdb"] = { kind = "tool", language = nil }, -- CouchDB
  ["cpp"] = { kind = "language", language = "C++" }, -- C++
  ["crystal"] = { kind = "language", language = "Crystal" }, -- Crystal
  ["css"] = { kind = "language", language = "CSS" }, -- CSS
  ["cyclejs"] = { kind = "package", language = "TypeScript" }, -- Cycle.js
  ["cypress"] = { kind = "package", language = "TypeScript" }, -- Cypress
  ["d"] = { kind = "language", language = "D" }, -- D
  ["d3"] = { kind = "package", language = "JavaScript" }, -- D3.js
  ["dart"] = { kind = "language", language = "Dart" }, -- Dart
  ["date_fns"] = { kind = "package", language = "TypeScript" }, -- date-fns
  ["deno"] = { kind = "package", language = "TypeScript" }, -- Deno
  ["django"] = { kind = "package", language = "Python" }, -- Django
  ["django_rest_framework"] = { kind = "package", language = "Python" }, -- Django REST Framework
  ["docker"] = { kind = "tool", language = nil }, -- Docker
  ["dojo"] = { kind = "package", language = "JavaScript" }, -- Dojo
  ["dom"] = { kind = "package", language = "JavaScript" }, -- Web APIs
  ["drupal"] = { kind = "package", language = "PHP" }, -- Drupal
  ["duckdb"] = { kind = "package", language = "SQL" }, -- DuckDB
  ["eigen3"] = { kind = "package", language = "C++" }, -- Eigen3
  ["electron"] = { kind = "package", language = "JavaScript" }, -- Electron
  ["elisp"] = { kind = "language", language = "Emacs Lisp" }, -- Elisp
  ["elixir"] = { kind = "language", language = "Elixir" }, -- Elixir
  ["ember"] = { kind = "package", language = "TypeScript" }, -- Ember.js
  ["enzyme"] = { kind = "package", language = "JavaScript" }, -- Enzyme
  ["erlang"] = { kind = "language", language = "Erlang" }, -- Erlang
  ["es_toolkit"] = { kind = "package", language = "TypeScript" }, -- es-toolkit
  ["esbuild"] = { kind = "package", language = "JavaScript" }, -- esbuild
  ["eslint"] = { kind = "package", language = "JavaScript" }, -- ESLint
  ["express"] = { kind = "package", language = "JavaScript" }, -- Express
  ["falcon"] = { kind = "package", language = "Python" }, -- Falcon
  ["fastapi"] = { kind = "package", language = "Python" }, -- FastAPI
  ["fish"] = { kind = "language", language = "fish" }, -- Fish
  ["flask"] = { kind = "package", language = "Python" }, -- Flask
  ["flow"] = { kind = "package", language = "JavaScript" }, -- Flow
  ["fluture"] = { kind = "package", language = "JavaScript" }, -- Fluture
  ["gcc"] = { kind = "package", language = "C" }, -- GCC
  ["git"] = { kind = "tool", language = nil }, -- Git
  ["gnu_cobol"] = { kind = "language", language = "COBOL" }, -- GnuCOBOL
  ["gnu_fortran"] = { kind = "language", language = "Fortran" }, -- GNU Fortran
  ["gnu_make"] = { kind = "tool", language = nil }, -- GNU Make
  ["gnuplot"] = { kind = "tool", language = nil }, -- Gnuplot
  ["go"] = { kind = "language", language = "Go" }, -- Go
  ["godot"] = { kind = "tool", language = nil }, -- Godot
  ["graphite"] = { kind = "tool", language = nil }, -- Graphite
  ["graphviz"] = { kind = "tool", language = nil }, -- Graphviz
  ["groovy"] = { kind = "language", language = "Groovy" }, -- Groovy
  ["grunt"] = { kind = "package", language = "JavaScript" }, -- Grunt
  ["gtk"] = { kind = "package", language = "C" }, -- GTK
  ["hammerspoon"] = { kind = "package", language = "Lua" }, -- Hammerspoon
  ["handlebars"] = { kind = "language", language = "Handlebars" }, -- Handlebars.js
  ["hapi"] = { kind = "package", language = "JavaScript" }, -- Hapi
  ["haproxy"] = { kind = "tool", language = nil }, -- HAProxy
  ["haskell"] = { kind = "language", language = "Haskell" }, -- Haskell
  ["haxe"] = { kind = "language", language = "Haxe" }, -- Haxe
  ["homebrew"] = { kind = "tool", language = nil }, -- Homebrew
  ["html"] = { kind = "language", language = "HTML" }, -- HTML
  ["htmx"] = { kind = "package", language = "JavaScript" }, -- htmx
  ["http"] = { kind = "tool", language = nil }, -- HTTP
  ["i3"] = { kind = "tool", language = nil }, -- i3
  ["immutable"] = { kind = "package", language = "TypeScript" }, -- Immutable.js
  ["influxdata"] = { kind = "tool", language = nil }, -- InfluxData
  ["jasmine"] = { kind = "package", language = "JavaScript" }, -- Jasmine
  ["javascript"] = { kind = "language", language = "JavaScript" }, -- JavaScript
  ["jekyll"] = { kind = "package", language = "Ruby" }, -- Jekyll
  ["jest"] = { kind = "package", language = "TypeScript" }, -- Jest
  ["jinja"] = { kind = "language", language = "Jinja" }, -- Jinja
  ["joi"] = { kind = "package", language = "JavaScript" }, -- Joi
  ["jq"] = { kind = "tool", language = nil }, -- jq
  ["jquery"] = { kind = "package", language = "JavaScript" }, -- jQuery
  ["jquerymobile"] = { kind = "package", language = "JavaScript" }, -- jQuery Mobile
  ["jqueryui"] = { kind = "package", language = "JavaScript" }, -- jQuery UI
  ["jsdoc"] = { kind = "package", language = "JavaScript" }, -- JSDoc
  ["julia"] = { kind = "language", language = "Julia" }, -- Julia
  ["knockout"] = { kind = "package", language = "JavaScript" }, -- Knockout.js
  ["koa"] = { kind = "package", language = "JavaScript" }, -- Koa
  ["kotlin"] = { kind = "language", language = "Kotlin" }, -- Kotlin
  ["kubectl"] = { kind = "tool", language = nil }, -- Kubectl
  ["kubernetes"] = { kind = "tool", language = nil }, -- Kubernetes
  ["laravel"] = { kind = "package", language = "PHP" }, -- Laravel
  ["latex"] = { kind = "language", language = "TeX" }, -- LaTeX
  ["leaflet"] = { kind = "package", language = "JavaScript" }, -- Leaflet
  ["less"] = { kind = "language", language = "Less" }, -- Less
  ["liquid"] = { kind = "language", language = "Liquid" }, -- Liquid
  ["lit"] = { kind = "package", language = "TypeScript" }, -- Lit
  ["lodash"] = { kind = "package", language = "JavaScript" }, -- lodash
  ["love"] = { kind = "package", language = "Lua" }, -- LÖVE
  ["lua"] = { kind = "language", language = "Lua" }, -- Lua
  ["man"] = { kind = "tool", language = nil }, -- Linux man pages
  ["maplibre_gl"] = { kind = "package", language = "TypeScript" }, -- MapLibre GL JS
  ["mariadb"] = { kind = "package", language = "SQL" }, -- MariaDB
  ["marionette"] = { kind = "package", language = "JavaScript" }, -- Marionette.js
  ["markdown"] = { kind = "language", language = "Markdown" }, -- Markdown
  ["matplotlib"] = { kind = "package", language = "Python" }, -- Matplotlib
  ["meteor"] = { kind = "package", language = "JavaScript" }, -- Meteor
  ["minitest"] = { kind = "package", language = "Ruby" }, -- Ruby / Minitest
  ["mocha"] = { kind = "package", language = "JavaScript" }, -- Mocha
  ["modernizr"] = { kind = "package", language = "JavaScript" }, -- Modernizr
  ["moment"] = { kind = "package", language = "JavaScript" }, -- Moment.js
  ["moment_timezone"] = { kind = "package", language = "JavaScript" }, -- Moment.js Timezone
  ["mongoose"] = { kind = "package", language = "JavaScript" }, -- Mongoose
  ["nextjs"] = { kind = "package", language = "JavaScript" }, -- Next.js
  ["nginx"] = { kind = "tool", language = nil }, -- nginx
  ["nginx_lua_module"] = { kind = "package", language = "Lua" }, -- nginx / Lua Module
  ["nim"] = { kind = "language", language = "Nim" }, -- Nim
  ["nix"] = { kind = "language", language = "Nix" }, -- Nix
  ["node"] = { kind = "package", language = "JavaScript" }, -- Node.js
  ["nokogiri"] = { kind = "package", language = "Ruby" }, -- Nokogiri
  ["npm"] = { kind = "package", language = "JavaScript" }, -- npm
  ["numpy"] = { kind = "package", language = "Python" }, -- NumPy
  ["nushell"] = { kind = "language", language = "Nushell" }, -- Nushell
  ["ocaml"] = { kind = "language", language = "OCaml" }, -- OCaml
  ["octave"] = { kind = "language", language = "MATLAB" }, -- Octave
  ["odin"] = { kind = "language", language = "Odin" }, -- Odin
  ["opengl"] = { kind = "package", language = "C" }, -- OpenGL
  ["openjdk"] = { kind = "language", language = "Java" }, -- OpenJDK
  ["openlayers"] = { kind = "package", language = "JavaScript" }, -- OpenLayers
  ["opentofu"] = { kind = "language", language = "HCL" }, -- OpenTofu
  ["opentsdb"] = { kind = "tool", language = nil }, -- OpenTSDB
  ["padrino"] = { kind = "package", language = "Ruby" }, -- Padrino
  ["pandas"] = { kind = "package", language = "Python" }, -- pandas
  ["perl"] = { kind = "language", language = "Perl" }, -- Perl
  ["phalcon"] = { kind = "package", language = "PHP" }, -- Phalcon
  ["phaser"] = { kind = "package", language = "JavaScript" }, -- Phaser
  ["phoenix"] = { kind = "package", language = "Elixir" }, -- Phoenix
  ["php"] = { kind = "language", language = "PHP" }, -- PHP
  ["phpunit"] = { kind = "package", language = "PHP" }, -- PHPUnit
  ["playwright"] = { kind = "package", language = "TypeScript" }, -- Playwright
  ["point_cloud_library"] = { kind = "package", language = "C++" }, -- PointCloudLibrary
  ["polars"] = { kind = "package", language = "Python" }, -- Polars
  ["pony"] = { kind = "language", language = "Pony" }, -- Pony
  ["postgresql"] = { kind = "language", language = "SQL" }, -- PostgreSQL
  ["powershell"] = { kind = "language", language = "PowerShell" }, -- PowerShell
  ["prettier"] = { kind = "package", language = "JavaScript" }, -- Prettier
  ["pug"] = { kind = "language", language = "Pug" }, -- Pug
  ["puppeteer"] = { kind = "package", language = "TypeScript" }, -- Puppeteer
  ["pygame"] = { kind = "package", language = "Python" }, -- Pygame
  ["pytest"] = { kind = "package", language = "Python" }, -- pytest
  ["python"] = { kind = "language", language = "Python" }, -- Python
  ["pytorch"] = { kind = "package", language = "Python" }, -- PyTorch
  ["q"] = { kind = "language", language = "q" }, -- Q
  ["qt"] = { kind = "package", language = "C++" }, -- Qt
  ["qunit"] = { kind = "package", language = "JavaScript" }, -- QUnit
  ["r"] = { kind = "language", language = "R" }, -- R
  ["rabbitmq"] = { kind = "tool", language = nil }, -- RabbitMQ
  ["rack"] = { kind = "package", language = "Ruby" }, -- Ruby / Rack
  ["rails"] = { kind = "package", language = "Ruby" }, -- Ruby on Rails
  ["ramda"] = { kind = "package", language = "JavaScript" }, -- Ramda
  ["react"] = { kind = "package", language = "JavaScript" }, -- React
  ["react_bootstrap"] = { kind = "package", language = "TypeScript" }, -- React Bootstrap
  ["react_native"] = { kind = "package", language = "JavaScript" }, -- React Native
  ["react_router"] = { kind = "package", language = "TypeScript" }, -- React Router
  ["reactivex"] = { kind = "package", language = "JavaScript" }, -- ReactiveX
  ["redis"] = { kind = "tool", language = nil }, -- Redis
  ["redux"] = { kind = "package", language = "TypeScript" }, -- Redux
  ["relay"] = { kind = "package", language = "JavaScript" }, -- Relay
  ["requests"] = { kind = "package", language = "Python" }, -- Requests
  ["requirejs"] = { kind = "package", language = "JavaScript" }, -- RequireJS
  ["rethinkdb"] = { kind = "tool", language = nil }, -- RethinkDB
  ["ruby"] = { kind = "language", language = "Ruby" }, -- Ruby
  ["rust"] = { kind = "language", language = "Rust" }, -- Rust
  ["rxjs"] = { kind = "package", language = "TypeScript" }, -- RxJS
  ["saltstack"] = { kind = "tool", language = nil }, -- SaltStack
  ["sanctuary"] = { kind = "package", language = "JavaScript" }, -- Sanctuary
  ["sanctuary_def"] = { kind = "package", language = "JavaScript" }, -- Sanctuary Def
  ["sanctuary_type_classes"] = { kind = "package", language = "JavaScript" }, -- Sanctuary Type Classes
  ["sass"] = { kind = "language", language = "SCSS" }, -- Sass
  ["scala"] = { kind = "language", language = "Scala" }, -- Scala
  ["scikit_image"] = { kind = "package", language = "Python" }, -- scikit-image
  ["scikit_learn"] = { kind = "package", language = "Python" }, -- scikit-learn
  ["sequelize"] = { kind = "package", language = "TypeScript" }, -- Sequelize
  ["sinon"] = { kind = "package", language = "JavaScript" }, -- Sinon.JS
  ["socketio"] = { kind = "package", language = "TypeScript" }, -- Socket.IO
  ["spring_boot"] = { kind = "package", language = "Java" }, -- Spring Boot
  ["sqlite"] = { kind = "language", language = "SQL" }, -- SQLite
  ["statsmodels"] = { kind = "package", language = "Python" }, -- Statsmodels
  ["svelte"] = { kind = "language", language = "Svelte" }, -- Svelte
  ["svg"] = { kind = "language", language = "SVG" }, -- SVG
  ["symfony"] = { kind = "package", language = "PHP" }, -- Symfony
  ["tailwindcss"] = { kind = "package", language = "CSS" }, -- Tailwind CSS
  ["tcl_tk"] = { kind = "language", language = "Tcl" }, -- Tcl/Tk
  ["tcllib"] = { kind = "package", language = "Tcl" }, -- Tcllib
  ["tensorflow"] = { kind = "package", language = "Python" }, -- TensorFlow
  ["tensorflow_cpp"] = { kind = "package", language = "C++" }, -- TensorFlow C++
  ["terraform"] = { kind = "language", language = "HCL" }, -- Terraform
  ["threejs"] = { kind = "package", language = "JavaScript" }, -- Three.js
  ["tokio"] = { kind = "package", language = "Rust" }, -- Tokio
  ["trio"] = { kind = "package", language = "Python" }, -- Trio
  ["twig"] = { kind = "language", language = "Twig" }, -- Twig
  ["typescript"] = { kind = "language", language = "TypeScript" }, -- TypeScript
  ["underscore"] = { kind = "package", language = "JavaScript" }, -- Underscore.js
  ["vagrant"] = { kind = "tool", language = nil }, -- Vagrant
  ["valibot"] = { kind = "package", language = "TypeScript" }, -- Valibot
  ["varnish"] = { kind = "tool", language = nil }, -- Varnish
  ["vertx"] = { kind = "package", language = "Java" }, -- Vert.x
  ["vite"] = { kind = "package", language = "TypeScript" }, -- Vite
  ["vitest"] = { kind = "package", language = "TypeScript" }, -- Vitest
  ["vue"] = { kind = "language", language = "Vue" }, -- Vue
  ["vue_router"] = { kind = "package", language = "JavaScript" }, -- Vue Router
  ["vueuse"] = { kind = "package", language = "TypeScript" }, -- VueUse
  ["vuex"] = { kind = "package", language = "JavaScript" }, -- Vuex
  ["vulkan"] = { kind = "package", language = "C" }, -- Vulkan
  ["wagtail"] = { kind = "package", language = "Python" }, -- Wagtail
  ["web_extensions"] = { kind = "package", language = "JavaScript" }, -- Web Extensions
  ["webpack"] = { kind = "package", language = "JavaScript" }, -- webpack
  ["werkzeug"] = { kind = "package", language = "Python" }, -- Werkzeug
  ["wordpress"] = { kind = "package", language = "PHP" }, -- WordPress
  ["xslt_xpath"] = { kind = "language", language = "XSLT" }, -- XSLT & XPath
  ["yarn"] = { kind = "package", language = "JavaScript" }, -- Yarn
  ["yii"] = { kind = "package", language = "PHP" }, -- Yii
  ["zig"] = { kind = "language", language = "Zig" }, -- Zig
  ["zsh"] = { kind = "language", language = "Shell" }, -- Zsh
}
