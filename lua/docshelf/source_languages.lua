-- Which language each devdocs source belongs to. Hand-maintained: this table
-- is the source of truth, not a detector.
--
-- Keyed by source family (the slug before "~": python~3.14 -> python). The
-- value names the language the source documents or belongs to. A tool is its
-- own language (git is Git, docker is Docker). Whether a source is the
-- language's own reference or a package of it is not stored here: it is
-- derived by the name rule in languages.lua (python, openjdk -> reference;
-- numpy -> package).
--
-- Seeded 2026-09-15 from each source's GitHub repository language and a name
-- match against Linguist, then corrected by hand: a repository's language is
-- what the program is written in (git: C), not what its documentation is for.
-- Families devdocs adds later are simply absent, and so unlinked.
return {
  ["angular"] = { language = "TypeScript" }, -- Angular
  ["angularjs"] = { language = "JavaScript" }, -- Angular.js
  ["ansible"] = { language = "Ansible" }, -- Ansible
  ["apache_http_server"] = { language = "Apache HTTP Server" }, -- Apache HTTP Server
  ["apache_pig"] = { language = "PigLatin" }, -- Apache Pig
  ["astro"] = { language = "Astro" }, -- Astro
  ["async"] = { language = "JavaScript" }, -- Async
  ["axios"] = { language = "JavaScript" }, -- Axios
  ["babel"] = { language = "TypeScript" }, -- Babel
  ["backbone"] = { language = "JavaScript" }, -- Backbone.js
  ["bash"] = { language = "Bash" }, -- Bash
  ["bazel"] = { language = "Bazel" }, -- Bazel
  ["bluebird"] = { language = "JavaScript" }, -- Bluebird
  ["bootstrap"] = { language = "CSS" }, -- Bootstrap
  ["bottle"] = { language = "Python" }, -- Bottle
  ["bower"] = { language = "Bower" }, -- Bower
  ["browser_support_tables"] = { language = "Browser Support Tables" }, -- Support Tables
  ["bun"] = { language = "JavaScript" }, -- Bun
  ["c"] = { language = "C" }, -- C
  ["cakephp"] = { language = "PHP" }, -- CakePHP
  ["celery"] = { language = "Python" }, -- Celery
  ["chai"] = { language = "JavaScript" }, -- Chai
  ["chef"] = { language = "Chef" }, -- Chef
  ["click"] = { language = "Python" }, -- click
  ["clojure"] = { language = "Clojure" }, -- Clojure
  ["cmake"] = { language = "CMake" }, -- CMake
  ["codeception"] = { language = "PHP" }, -- Codeception
  ["codeceptjs"] = { language = "JavaScript" }, -- CodeceptJS
  ["codeigniter"] = { language = "PHP" }, -- CodeIgniter
  ["coffeescript"] = { language = "CoffeeScript" }, -- CoffeeScript
  ["coldfusion"] = { language = "ColdFusion" }, -- ColdFusion
  ["composer"] = { language = "PHP" }, -- Composer
  ["cordova"] = { language = "JavaScript" }, -- Cordova
  ["couchdb"] = { language = "CouchDB" }, -- CouchDB
  ["cpp"] = { language = "C++" }, -- C++
  ["crystal"] = { language = "Crystal" }, -- Crystal
  ["css"] = { language = "CSS" }, -- CSS
  ["cyclejs"] = { language = "TypeScript" }, -- Cycle.js
  ["cypress"] = { language = "TypeScript" }, -- Cypress
  ["d"] = { language = "D" }, -- D
  ["d3"] = { language = "JavaScript" }, -- D3.js
  ["dart"] = { language = "Dart" }, -- Dart
  ["date_fns"] = { language = "TypeScript" }, -- date-fns
  ["deno"] = { language = "TypeScript" }, -- Deno
  ["django"] = { language = "Python" }, -- Django
  ["django_rest_framework"] = { language = "Python" }, -- Django REST Framework
  ["docker"] = { language = "Docker" }, -- Docker
  ["dojo"] = { language = "JavaScript" }, -- Dojo
  ["dom"] = { language = "JavaScript" }, -- Web APIs
  ["drupal"] = { language = "PHP" }, -- Drupal
  ["duckdb"] = { language = "DuckDB" }, -- DuckDB
  ["eigen3"] = { language = "C++" }, -- Eigen3
  ["electron"] = { language = "JavaScript" }, -- Electron
  ["elisp"] = { language = "Emacs Lisp" }, -- Elisp
  ["elixir"] = { language = "Elixir" }, -- Elixir
  ["ember"] = { language = "TypeScript" }, -- Ember.js
  ["enzyme"] = { language = "JavaScript" }, -- Enzyme
  ["erlang"] = { language = "Erlang" }, -- Erlang
  ["es_toolkit"] = { language = "TypeScript" }, -- es-toolkit
  ["esbuild"] = { language = "JavaScript" }, -- esbuild
  ["eslint"] = { language = "JavaScript" }, -- ESLint
  ["express"] = { language = "JavaScript" }, -- Express
  ["falcon"] = { language = "Python" }, -- Falcon
  ["fastapi"] = { language = "Python" }, -- FastAPI
  ["fish"] = { language = "Fish" }, -- Fish
  ["flask"] = { language = "Python" }, -- Flask
  ["flow"] = { language = "JavaScript" }, -- Flow
  ["fluture"] = { language = "JavaScript" }, -- Fluture
  ["gcc"] = { language = "C" }, -- GCC
  ["git"] = { language = "Git" }, -- Git
  ["gnu_cobol"] = { language = "COBOL" }, -- GnuCOBOL
  ["gnu_fortran"] = { language = "Fortran" }, -- GNU Fortran
  ["gnu_make"] = { language = "GNU Make" }, -- GNU Make
  ["gnuplot"] = { language = "Gnuplot" }, -- Gnuplot
  ["go"] = { language = "Go" }, -- Go
  ["godot"] = { language = "Godot" }, -- Godot
  ["graphite"] = { language = "Graphite" }, -- Graphite
  ["graphviz"] = { language = "Graphviz" }, -- Graphviz
  ["groovy"] = { language = "Groovy" }, -- Groovy
  ["grunt"] = { language = "JavaScript" }, -- Grunt
  ["gtk"] = { language = "C" }, -- GTK
  ["hammerspoon"] = { language = "Lua" }, -- Hammerspoon
  ["handlebars"] = { language = "Handlebars" }, -- Handlebars.js
  ["hapi"] = { language = "JavaScript" }, -- Hapi
  ["haproxy"] = { language = "HAProxy" }, -- HAProxy
  ["haskell"] = { language = "Haskell" }, -- Haskell
  ["haxe"] = { language = "Haxe" }, -- Haxe
  ["homebrew"] = { language = "Homebrew" }, -- Homebrew
  ["html"] = { language = "HTML" }, -- HTML
  ["htmx"] = { language = "JavaScript" }, -- htmx
  ["http"] = { language = "HTTP" }, -- HTTP
  ["i3"] = { language = "i3" }, -- i3
  ["immutable"] = { language = "TypeScript" }, -- Immutable.js
  ["influxdata"] = { language = "InfluxData" }, -- InfluxData
  ["jasmine"] = { language = "JavaScript" }, -- Jasmine
  ["javascript"] = { language = "JavaScript" }, -- JavaScript
  ["jekyll"] = { language = "Ruby" }, -- Jekyll
  ["jest"] = { language = "TypeScript" }, -- Jest
  ["jinja"] = { language = "Jinja" }, -- Jinja
  ["joi"] = { language = "JavaScript" }, -- Joi
  ["jq"] = { language = "jq" }, -- jq
  ["jquery"] = { language = "JavaScript" }, -- jQuery
  ["jquerymobile"] = { language = "JavaScript" }, -- jQuery Mobile
  ["jqueryui"] = { language = "JavaScript" }, -- jQuery UI
  ["jsdoc"] = { language = "JavaScript" }, -- JSDoc
  ["julia"] = { language = "Julia" }, -- Julia
  ["knockout"] = { language = "JavaScript" }, -- Knockout.js
  ["koa"] = { language = "JavaScript" }, -- Koa
  ["kotlin"] = { language = "Kotlin" }, -- Kotlin
  ["kubectl"] = { language = "Kubectl" }, -- Kubectl
  ["kubernetes"] = { language = "Kubernetes" }, -- Kubernetes
  ["laravel"] = { language = "PHP" }, -- Laravel
  ["latex"] = { language = "LaTeX" }, -- LaTeX
  ["leaflet"] = { language = "JavaScript" }, -- Leaflet
  ["less"] = { language = "Less" }, -- Less
  ["liquid"] = { language = "Liquid" }, -- Liquid
  ["lit"] = { language = "TypeScript" }, -- Lit
  ["lodash"] = { language = "JavaScript" }, -- lodash
  ["love"] = { language = "Lua" }, -- LÖVE
  ["lua"] = { language = "Lua" }, -- Lua
  ["man"] = { language = "Linux man pages" }, -- Linux man pages
  ["maplibre_gl"] = { language = "TypeScript" }, -- MapLibre GL JS
  ["mariadb"] = { language = "MariaDB" }, -- MariaDB
  ["marionette"] = { language = "JavaScript" }, -- Marionette.js
  ["markdown"] = { language = "Markdown" }, -- Markdown
  ["matplotlib"] = { language = "Python" }, -- Matplotlib
  ["meteor"] = { language = "JavaScript" }, -- Meteor
  ["minitest"] = { language = "Ruby" }, -- Ruby / Minitest
  ["mocha"] = { language = "JavaScript" }, -- Mocha
  ["modernizr"] = { language = "JavaScript" }, -- Modernizr
  ["moment"] = { language = "JavaScript" }, -- Moment.js
  ["moment_timezone"] = { language = "JavaScript" }, -- Moment.js Timezone
  ["mongoose"] = { language = "JavaScript" }, -- Mongoose
  ["nextjs"] = { language = "JavaScript" }, -- Next.js
  ["nginx"] = { language = "nginx" }, -- nginx
  ["nginx_lua_module"] = { language = "Lua" }, -- nginx / Lua Module
  ["nim"] = { language = "Nim" }, -- Nim
  ["nix"] = { language = "Nix" }, -- Nix
  ["node"] = { language = "JavaScript" }, -- Node.js
  ["nokogiri"] = { language = "Ruby" }, -- Nokogiri
  ["npm"] = { language = "JavaScript" }, -- npm
  ["numpy"] = { language = "Python" }, -- NumPy
  ["nushell"] = { language = "Nushell" }, -- Nushell
  ["ocaml"] = { language = "OCaml" }, -- OCaml
  ["octave"] = { language = "MATLAB" }, -- Octave
  ["odin"] = { language = "Odin" }, -- Odin
  ["opengl"] = { language = "C" }, -- OpenGL
  ["openjdk"] = { language = "Java" }, -- OpenJDK
  ["openlayers"] = { language = "JavaScript" }, -- OpenLayers
  ["opentofu"] = { language = "HCL" }, -- OpenTofu
  ["opentsdb"] = { language = "OpenTSDB" }, -- OpenTSDB
  ["padrino"] = { language = "Ruby" }, -- Padrino
  ["pandas"] = { language = "Python" }, -- pandas
  ["perl"] = { language = "Perl" }, -- Perl
  ["phalcon"] = { language = "PHP" }, -- Phalcon
  ["phaser"] = { language = "JavaScript" }, -- Phaser
  ["phoenix"] = { language = "Elixir" }, -- Phoenix
  ["php"] = { language = "PHP" }, -- PHP
  ["phpunit"] = { language = "PHP" }, -- PHPUnit
  ["playwright"] = { language = "TypeScript" }, -- Playwright
  ["point_cloud_library"] = { language = "C++" }, -- PointCloudLibrary
  ["polars"] = { language = "Python" }, -- Polars
  ["pony"] = { language = "Pony" }, -- Pony
  ["postgresql"] = { language = "PostgreSQL" }, -- PostgreSQL
  ["powershell"] = { language = "PowerShell" }, -- PowerShell
  ["prettier"] = { language = "JavaScript" }, -- Prettier
  ["pug"] = { language = "Pug" }, -- Pug
  ["puppeteer"] = { language = "TypeScript" }, -- Puppeteer
  ["pygame"] = { language = "Python" }, -- Pygame
  ["pytest"] = { language = "Python" }, -- pytest
  ["python"] = { language = "Python" }, -- Python
  ["pytorch"] = { language = "Python" }, -- PyTorch
  ["q"] = { language = "q" }, -- Q
  ["qt"] = { language = "C++" }, -- Qt
  ["qunit"] = { language = "JavaScript" }, -- QUnit
  ["r"] = { language = "R" }, -- R
  ["rabbitmq"] = { language = "RabbitMQ" }, -- RabbitMQ
  ["rack"] = { language = "Ruby" }, -- Ruby / Rack
  ["rails"] = { language = "Ruby" }, -- Ruby on Rails
  ["ramda"] = { language = "JavaScript" }, -- Ramda
  ["react"] = { language = "JavaScript" }, -- React
  ["react_bootstrap"] = { language = "TypeScript" }, -- React Bootstrap
  ["react_native"] = { language = "JavaScript" }, -- React Native
  ["react_router"] = { language = "TypeScript" }, -- React Router
  ["reactivex"] = { language = "JavaScript" }, -- ReactiveX
  ["redis"] = { language = "Redis" }, -- Redis
  ["redux"] = { language = "TypeScript" }, -- Redux
  ["relay"] = { language = "JavaScript" }, -- Relay
  ["requests"] = { language = "Python" }, -- Requests
  ["requirejs"] = { language = "JavaScript" }, -- RequireJS
  ["rethinkdb"] = { language = "RethinkDB" }, -- RethinkDB
  ["ruby"] = { language = "Ruby" }, -- Ruby
  ["rust"] = { language = "Rust" }, -- Rust
  ["rxjs"] = { language = "TypeScript" }, -- RxJS
  ["saltstack"] = { language = "SaltStack" }, -- SaltStack
  ["sanctuary"] = { language = "JavaScript" }, -- Sanctuary
  ["sanctuary_def"] = { language = "JavaScript" }, -- Sanctuary Def
  ["sanctuary_type_classes"] = { language = "JavaScript" }, -- Sanctuary Type Classes
  ["sass"] = { language = "Sass" }, -- Sass
  ["scala"] = { language = "Scala" }, -- Scala
  ["scikit_image"] = { language = "Python" }, -- scikit-image
  ["scikit_learn"] = { language = "Python" }, -- scikit-learn
  ["sequelize"] = { language = "TypeScript" }, -- Sequelize
  ["sinon"] = { language = "JavaScript" }, -- Sinon.JS
  ["socketio"] = { language = "TypeScript" }, -- Socket.IO
  ["spring_boot"] = { language = "Java" }, -- Spring Boot
  ["sqlite"] = { language = "SQLite" }, -- SQLite
  ["statsmodels"] = { language = "Python" }, -- Statsmodels
  ["svelte"] = { language = "Svelte" }, -- Svelte
  ["svg"] = { language = "SVG" }, -- SVG
  ["symfony"] = { language = "PHP" }, -- Symfony
  ["tailwindcss"] = { language = "CSS" }, -- Tailwind CSS
  ["tcl_tk"] = { language = "Tcl" }, -- Tcl/Tk
  ["tcllib"] = { language = "Tcl" }, -- Tcllib
  ["tensorflow"] = { language = "Python" }, -- TensorFlow
  ["tensorflow_cpp"] = { language = "C++" }, -- TensorFlow C++
  ["terraform"] = { language = "HCL" }, -- Terraform
  ["threejs"] = { language = "JavaScript" }, -- Three.js
  ["tokio"] = { language = "Rust" }, -- Tokio
  ["trio"] = { language = "Python" }, -- Trio
  ["twig"] = { language = "Twig" }, -- Twig
  ["typescript"] = { language = "TypeScript" }, -- TypeScript
  ["underscore"] = { language = "JavaScript" }, -- Underscore.js
  ["vagrant"] = { language = "Vagrant" }, -- Vagrant
  ["valibot"] = { language = "TypeScript" }, -- Valibot
  ["varnish"] = { language = "Varnish" }, -- Varnish
  ["vertx"] = { language = "Java" }, -- Vert.x
  ["vite"] = { language = "TypeScript" }, -- Vite
  ["vitest"] = { language = "TypeScript" }, -- Vitest
  ["vue"] = { language = "Vue" }, -- Vue
  ["vue_router"] = { language = "JavaScript" }, -- Vue Router
  ["vueuse"] = { language = "TypeScript" }, -- VueUse
  ["vuex"] = { language = "JavaScript" }, -- Vuex
  ["vulkan"] = { language = "C" }, -- Vulkan
  ["wagtail"] = { language = "Python" }, -- Wagtail
  ["web_extensions"] = { language = "JavaScript" }, -- Web Extensions
  ["webpack"] = { language = "JavaScript" }, -- webpack
  ["werkzeug"] = { language = "Python" }, -- Werkzeug
  ["wordpress"] = { language = "PHP" }, -- WordPress
  ["xslt_xpath"] = { language = "XSLT" }, -- XSLT & XPath
  ["yarn"] = { language = "JavaScript" }, -- Yarn
  ["yii"] = { language = "PHP" }, -- Yii
  ["zig"] = { language = "Zig" }, -- Zig
  ["zsh"] = { language = "Zsh" }, -- Zsh
}
