require "spec_helper"

describe "bundle install with git sources" do
  describe "when floating on master" do
    before :each do
      build_git "foo" do |s|
        s.executables = "foobar"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        git "#{lib_path('foo-1.0')}" do
          gem 'foo'
        end
      G
    end

    it "fetches gems" do
      should_be_installed("foo 1.0")

      run <<-RUBY
        require 'foo'
        puts "WIN" unless defined?(FOO_PREV_REF)
      RUBY

      expect(out).to eq("WIN")
    end

    it "caches the git repo" do
      expect(Dir["#{default_bundle_path}/cache/bundler/git/foo-1.0-*"].size).to eq(1)
    end

    it "caches the evaluated gemspec" do
      git = update_git "foo" do |s|
        s.executables = ["foobar"] # we added this the first time, so keep it now
        s.files = ["bin/foobar"] # updating git nukes the files list
        foospec = s.to_ruby.gsub(/s\.files.*/, 's.files = `git ls-files`.split("\n")')
        s.write "foo.gemspec", foospec
      end

      bundle "update foo"

      sha = git.ref_for("master", 11)
      spec_file = default_bundle_path.join("bundler/gems/foo-1.0-#{sha}/foo.gemspec").to_s
      ruby_code = Gem::Specification.load(spec_file).to_ruby
      file_code = File.read(spec_file)
      expect(file_code).to eq(ruby_code)
    end

    it "does not update the git source implicitly" do
      update_git "foo"

      in_app_root2 do
        install_gemfile bundled_app2("Gemfile"), <<-G
          git "#{lib_path('foo-1.0')}" do
            gem 'foo'
          end
        G
      end

      in_app_root do
        run <<-RUBY
          require 'foo'
          puts "fail" if defined?(FOO_PREV_REF)
        RUBY

        expect(out).to be_empty
      end
    end

    it "sets up git gem executables on the path" do
      pending_jruby_shebang_fix
      bundle "exec foobar"
      expect(out).to eq("1.0")
    end

    it "complains if pinned specs don't exist in the git repo" do
      build_git "foo"

      install_gemfile <<-G
        gem "foo", "1.1", :git => "#{lib_path('foo-1.0')}"
      G

      expect(out).to include("Source contains 'foo' at: 1.0")
    end

    it "still works after moving the application directory" do
      bundle "install --path vendor/bundle"
      FileUtils.mv bundled_app, tmp('bundled_app.bck')

      Dir.chdir tmp('bundled_app.bck')
      should_be_installed "foo 1.0"
    end

    it "can still install after moving the application directory" do
      bundle "install --path vendor/bundle"
      FileUtils.mv bundled_app, tmp('bundled_app.bck')

      update_git "foo", "1.1", :path => lib_path("foo-1.0")

      Dir.chdir tmp('bundled_app.bck')
      gemfile tmp('bundled_app.bck/Gemfile'), <<-G
        source "file://#{gem_repo1}"
        git "#{lib_path('foo-1.0')}" do
          gem 'foo'
        end

        gem "rack", "1.0"
      G

      bundle "update foo"

      should_be_installed "foo 1.1", "rack 1.0"
    end

  end

  describe "with an empty git block" do
    before do
      build_git "foo"
      gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack"

        git "#{lib_path("foo-1.0")}" do
          # this page left intentionally blank
        end
      G
    end

    it "does not explode" do
      bundle "install"
      should_be_installed "rack 1.0"
    end
  end

  describe "when specifying a revision" do
    before(:each) do
      build_git "foo"
      @revision = revision_for(lib_path("foo-1.0"))
      update_git "foo"
    end

    it "works" do
      install_gemfile <<-G
        git "#{lib_path('foo-1.0')}", :ref => "#{@revision}" do
          gem "foo"
        end
      G

      run <<-RUBY
        require 'foo'
        puts "WIN" unless defined?(FOO_PREV_REF)
      RUBY

      expect(out).to eq("WIN")
    end

    it "works when the revision is a symbol" do
      install_gemfile <<-G
        git "#{lib_path('foo-1.0')}", :ref => #{@revision.to_sym.inspect} do
          gem "foo"
        end
      G
      expect(err).to eq("")

      run <<-RUBY
        require 'foo'
        puts "WIN" unless defined?(FOO_PREV_REF)
      RUBY

      expect(out).to eq("WIN")
    end
  end

  describe "when specifying local override" do
    it "uses the local repository instead of checking a new one out" do
      # We don't generate it because we actually don't need it
      # build_git "rack", "0.8"

      build_git "rack", "0.8", :path => lib_path('local-rack') do |s|
        s.write "lib/rack.rb", "puts :LOCAL"
      end

      gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install
      expect(out).to match(/at #{lib_path('local-rack')}/)

      run "require 'rack'"
      expect(out).to eq("LOCAL")
    end

    it "chooses the local repository on runtime" do
      build_git "rack", "0.8"

      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))

      update_git "rack", "0.8", :path => lib_path('local-rack') do |s|
        s.write "lib/rack.rb", "puts :LOCAL"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      run "require 'rack'"
      expect(out).to eq("LOCAL")
    end

    it "updates specs on runtime" do
      system_gems "nokogiri-1.4.2"

      build_git "rack", "0.8"

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      lockfile0 = File.read(bundled_app("Gemfile.lock"))

      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))
      update_git "rack", "0.8", :path => lib_path('local-rack') do |s|
        s.add_dependency "nokogiri", "1.4.2"
      end

      bundle %|config local.rack #{lib_path('local-rack')}|
      run "require 'rack'"

      lockfile1 = File.read(bundled_app("Gemfile.lock"))
      expect(lockfile1).not_to eq(lockfile0)
    end

    it "updates ref on install" do
      build_git "rack", "0.8"

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      lockfile0 = File.read(bundled_app("Gemfile.lock"))

      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))
      update_git "rack", "0.8", :path => lib_path('local-rack')

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install

      lockfile1 = File.read(bundled_app("Gemfile.lock"))
      expect(lockfile1).not_to eq(lockfile0)
    end

    it "explodes if given path does not exist on install" do
      build_git "rack", "0.8"

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install
      expect(out).to match(/Cannot use local override for rack-0.8 because #{Regexp.escape(lib_path('local-rack').to_s)} does not exist/)
    end

    it "explodes if branch is not given on install" do
      build_git "rack", "0.8"
      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install
      expect(out).to match(/cannot use local override/i)
    end

    it "does not explode if disable_local_branch_check is given" do
      build_git "rack", "0.8"
      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle %|config disable_local_branch_check true|
      bundle :install
      expect(out).to match(/Your bundle is complete!/)
    end

    it "explodes on different branches on install" do
      build_git "rack", "0.8"

      FileUtils.cp_r("#{lib_path('rack-0.8')}/.", lib_path('local-rack'))

      update_git "rack", "0.8", :path => lib_path('local-rack'), :branch => "another" do |s|
        s.write "lib/rack.rb", "puts :LOCAL"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install
      expect(out).to match(/is using branch another but Gemfile specifies master/)
    end

    it "explodes on invalid revision on install" do
      build_git "rack", "0.8"

      build_git "rack", "0.8", :path => lib_path('local-rack') do |s|
        s.write "lib/rack.rb", "puts :LOCAL"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}", :branch => "master"
      G

      bundle %|config local.rack #{lib_path('local-rack')}|
      bundle :install
      expect(out).to match(/The Gemfile lock is pointing to revision \w+/)
    end
  end

  describe "specified inline" do
    # TODO: Figure out how to write this test so that it is not flaky depending
    #       on the current network situation.
    # it "supports private git URLs" do
    #   gemfile <<-G
    #     gem "thingy", :git => "git@notthere.fallingsnow.net:somebody/thingy.git"
    #   G
    #
    #   bundle :install, :expect_err => true
    #
    #   # p out
    #   # p err
    #   puts err unless err.empty? # This spec fails randomly every so often
    #   err.should include("notthere.fallingsnow.net")
    #   err.should include("ssh")
    # end

    it "installs from git even if a newer gem is available elsewhere" do
      build_git "rack", "0.8"

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack-0.8')}"
      G

      should_be_installed "rack 0.8"
    end

    it "installs dependencies from git even if a newer gem is available elsewhere" do
      system_gems "rack-1.0.0"

      build_lib "rack", "1.0", :path => lib_path('nested/bar') do |s|
        s.write "lib/rack.rb", "puts 'WIN OVERRIDE'"
      end

      build_git "foo", :path => lib_path('nested') do |s|
        s.add_dependency "rack", "= 1.0"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "foo", :git => "#{lib_path('nested')}"
      G

      run "require 'rack'"
      expect(out).to eq('WIN OVERRIDE')
    end

    it "correctly unlocks when changing to a git source" do
      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", "0.9.1"
      G

      build_git "rack", :path => lib_path("rack")

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", "1.0.0", :git => "#{lib_path('rack')}"
      G

      should_be_installed "rack 1.0.0"
    end

    it "correctly unlocks when changing to a git source without versions" do
      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack"
      G

      build_git "rack", "1.2", :path => lib_path("rack")

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack", :git => "#{lib_path('rack')}"
      G

      should_be_installed "rack 1.2"
    end
  end

  describe "block syntax" do
    it "pulls all gems from a git block" do
      build_lib "omg", :path => lib_path('hi2u/omg')
      build_lib "hi2u", :path => lib_path('hi2u')

      install_gemfile <<-G
        path "#{lib_path('hi2u')}" do
          gem "omg"
          gem "hi2u"
        end
      G

      should_be_installed "omg 1.0", "hi2u 1.0"
    end
  end

  it "uses a ref if specified" do
    build_git "foo"
    @revision = revision_for(lib_path("foo-1.0"))
    update_git "foo"

    install_gemfile <<-G
      gem "foo", :git => "#{lib_path('foo-1.0')}", :ref => "#{@revision}"
    G

    run <<-RUBY
      require 'foo'
      puts "WIN" unless defined?(FOO_PREV_REF)
    RUBY

    expect(out).to eq("WIN")
  end

  it "correctly handles cases with invalid gemspecs" do
    build_git "foo" do |s|
      s.summary = nil
    end

    install_gemfile <<-G
      source "file://#{gem_repo1}"
      gem "foo", :git => "#{lib_path('foo-1.0')}"
      gem "rails", "2.3.2"
    G

    should_be_installed "foo 1.0"
    should_be_installed "rails 2.3.2"
  end

  it "runs the gemspec in the context of its parent directory" do
    build_lib "bar", :path => lib_path("foo/bar"), :gemspec => false do |s|
      s.write lib_path("foo/bar/lib/version.rb"), %{BAR_VERSION = '1.0'}
      s.write "bar.gemspec", <<-G
        $:.unshift Dir.pwd # For 1.9
        require 'lib/version'
        Gem::Specification.new do |s|
          s.name        = 'bar'
          s.version     = BAR_VERSION
          s.summary     = 'Bar'
          s.files       = Dir["lib/**/*.rb"]
        end
      G
    end

    build_git "foo", :path => lib_path("foo") do |s|
      s.write "bin/foo", ""
    end

    install_gemfile <<-G
      source "file://#{gem_repo1}"
      gem "bar", :git => "#{lib_path("foo")}"
      gem "rails", "2.3.2"
    G

    should_be_installed "bar 1.0"
    should_be_installed "rails 2.3.2"
  end

  it "installs from git even if a rubygems gem is present" do
    build_gem "foo", "1.0", :path => lib_path('fake_foo'), :to_system => true do |s|
      s.write "lib/foo.rb", "raise 'FAIL'"
    end

    build_git "foo", "1.0"

    install_gemfile <<-G
      gem "foo", "1.0", :git => "#{lib_path('foo-1.0')}"
    G

    should_be_installed "foo 1.0"
  end

  it "fakes the gem out if there is no gemspec" do
    build_git "foo", :gemspec => false

    install_gemfile <<-G
      source "file://#{gem_repo1}"
      gem "foo", "1.0", :git => "#{lib_path('foo-1.0')}"
      gem "rails", "2.3.2"
    G

    should_be_installed("foo 1.0")
    should_be_installed("rails 2.3.2")
  end

  it "catches git errors and spits out useful output" do
    gemfile <<-G
      gem "foo", "1.0", :git => "omgomg"
    G

    bundle :install, :expect_err => true

    expect(out).to include("Git error:")
    expect(err).to include("fatal")
    expect(err).to include("omgomg")
  end

  it "works when the gem path has spaces in it" do
    build_git "foo", :path => lib_path('foo space-1.0')

    install_gemfile <<-G
      gem "foo", :git => "#{lib_path('foo space-1.0')}"
    G

    should_be_installed "foo 1.0"
  end

  it "handles repos that have been force-pushed" do
    build_git "forced", "1.0"

    install_gemfile <<-G
      git "#{lib_path('forced-1.0')}" do
        gem 'forced'
      end
    G
    should_be_installed "forced 1.0"

    update_git "forced" do |s|
      s.write "lib/forced.rb", "FORCED = '1.1'"
    end

    bundle "update"
    should_be_installed "forced 1.1"

    Dir.chdir(lib_path('forced-1.0')) do
      `git reset --hard HEAD^`
    end

    bundle "update"
    should_be_installed "forced 1.0"
  end

  it "ignores submodules if :submodule is not passed" do
    build_git "submodule", "1.0"
    build_git "has_submodule", "1.0" do |s|
      s.add_dependency "submodule"
    end
    Dir.chdir(lib_path('has_submodule-1.0')) do
      `git submodule add #{lib_path('submodule-1.0')} submodule-1.0`
      `git commit -m "submodulator"`
    end

    install_gemfile <<-G, :expect_err => true
      git "#{lib_path('has_submodule-1.0')}" do
        gem "has_submodule"
      end
    G
    expect(out).to match(/could not find gem 'submodule/i)

    should_not_be_installed "has_submodule 1.0", :expect_err => true
  end

  it "handles repos with submodules" do
    build_git "submodule", "1.0"
    build_git "has_submodule", "1.0" do |s|
      s.add_dependency "submodule"
    end
    Dir.chdir(lib_path('has_submodule-1.0')) do
      `git submodule add #{lib_path('submodule-1.0')} submodule-1.0`
      `git commit -m "submodulator"`
    end

    install_gemfile <<-G
      git "#{lib_path('has_submodule-1.0')}", :submodules => true do
        gem "has_submodule"
      end
    G

    should_be_installed "has_submodule 1.0"
  end

  it "handles implicit updates when modifying the source info" do
    git = build_git "foo"

    install_gemfile <<-G
      git "#{lib_path('foo-1.0')}" do
        gem "foo"
      end
    G

    update_git "foo"
    update_git "foo"

    install_gemfile <<-G
      git "#{lib_path('foo-1.0')}", :ref => "#{git.ref_for('HEAD^')}" do
        gem "foo"
      end
    G

    run <<-RUBY
      require 'foo'
      puts "WIN" if FOO_PREV_REF == '#{git.ref_for("HEAD^^")}'
    RUBY

    expect(out).to eq("WIN")
  end

  it "does not to a remote fetch if the revision is cached locally" do
    build_git "foo"

    install_gemfile <<-G
      gem "foo", :git => "#{lib_path('foo-1.0')}"
    G

    FileUtils.rm_rf(lib_path('foo-1.0'))

    bundle "install"
    expect(out).not_to match(/updating/i)
  end

  it "doesn't blow up if bundle install is run twice in a row" do
    build_git "foo"

    gemfile <<-G
      gem "foo", :git => "#{lib_path('foo-1.0')}"
    G

    bundle "install"
    bundle "install", :exitstatus => true
    expect(exitstatus).to eq(0)
  end

  it "does not duplicate git gem sources" do
    build_lib "foo", :path => lib_path('nested/foo')
    build_lib "bar", :path => lib_path('nested/bar')

    build_git "foo", :path => lib_path('nested')
    build_git "bar", :path => lib_path('nested')

    gemfile <<-G
      gem "foo", :git => "#{lib_path('nested')}"
      gem "bar", :git => "#{lib_path('nested')}"
    G

    bundle "install"
    expect(File.read(bundled_app("Gemfile.lock")).scan('GIT').size).to eq(1)
  end

  describe "switching sources" do
    it "doesn't explode when switching Path to Git sources" do
      build_gem "foo", "1.0", :to_system => true do |s|
        s.write "lib/foo.rb", "raise 'fail'"
      end
      build_lib "foo", "1.0", :path => lib_path('bar/foo')
      build_git "bar", "1.0", :path => lib_path('bar') do |s|
        s.add_dependency 'foo'
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "bar", :path => "#{lib_path('bar')}"
      G

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "bar", :git => "#{lib_path('bar')}"
      G

      should_be_installed "foo 1.0", "bar 1.0"
    end

    it "doesn't explode when switching Gem to Git source" do
      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack-obama"
        gem "rack", "1.0.0"
      G

      build_git "rack", "1.0" do |s|
        s.write "lib/new_file.rb", "puts 'USING GIT'"
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "rack-obama"
        gem "rack", "1.0.0", :git => "#{lib_path("rack-1.0")}"
      G

      run "require 'new_file'"
      expect(out).to eq("USING GIT")
    end
  end

  describe "bundle install after the remote has been updated" do
    it "installs" do
      build_git "valim"

      install_gemfile <<-G
        gem "valim", :git => "file://#{lib_path("valim-1.0")}"
      G

      old_revision = revision_for(lib_path("valim-1.0"))
      update_git "valim"
      new_revision = revision_for(lib_path("valim-1.0"))

      lockfile = File.read(bundled_app("Gemfile.lock"))
      File.open(bundled_app("Gemfile.lock"), "w") do |file|
        file.puts lockfile.gsub(/revision: #{old_revision}/, "revision: #{new_revision}")
      end

      bundle "install"

      run <<-R
        require "valim"
        puts VALIM_PREV_REF
      R

      expect(out).to eq(old_revision)
    end
  end

  describe "bundle install --deployment with git sources" do
    it "works" do
      build_git "valim", :path => lib_path('valim')

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "valim", "= 1.0", :git => "#{lib_path('valim')}"
      G

      simulate_new_machine

      bundle "install --deployment", :exitstatus => true
      expect(exitstatus).to eq(0)
    end
  end

  describe "gem install hooks" do
    it "runs pre-install hooks" do
      build_git "foo"
      gemfile <<-G
        gem "foo", :git => "#{lib_path('foo-1.0')}"
      G

      File.open(lib_path("install_hooks.rb"), "w") do |h|
        h.write <<-H
          require 'rubygems'
          Gem.pre_install_hooks << lambda do |inst|
            STDERR.puts "Ran pre-install hook: \#{inst.spec.full_name}"
          end
        H
      end

      bundle :install, :expect_err => true,
        :requires => [lib_path('install_hooks.rb')]
      expect(err).to eq("Ran pre-install hook: foo-1.0")
    end

    it "runs post-install hooks" do
      build_git "foo"
      gemfile <<-G
        gem "foo", :git => "#{lib_path('foo-1.0')}"
      G

      File.open(lib_path("install_hooks.rb"), "w") do |h|
        h.write <<-H
          require 'rubygems'
          Gem.post_install_hooks << lambda do |inst|
            STDERR.puts "Ran post-install hook: \#{inst.spec.full_name}"
          end
        H
      end

      bundle :install, :expect_err => true,
        :requires => [lib_path('install_hooks.rb')]
      expect(err).to eq("Ran post-install hook: foo-1.0")
    end

    it "complains if the install hook fails" do
      build_git "foo"
      gemfile <<-G
        gem "foo", :git => "#{lib_path('foo-1.0')}"
      G

      File.open(lib_path("install_hooks.rb"), "w") do |h|
        h.write <<-H
          require 'rubygems'
          Gem.pre_install_hooks << lambda do |inst|
            false
          end
        H
      end

      bundle :install, :expect_err => true,
        :requires => [lib_path('install_hooks.rb')]
      expect(out).to include("failed for foo-1.0")
    end
  end

  context "with an extension" do
    it "installs the extension" do
      build_git "foo" do |s|
        s.add_dependency "rake"
        s.extensions << "Rakefile"
        s.write "Rakefile", <<-RUBY
          task :default do
            path = File.expand_path("../lib", __FILE__)
            FileUtils.mkdir_p(path)
            File.open("\#{path}/foo.rb", "w") do |f|
              f.puts "FOO = 'YES'"
            end
          end
        RUBY
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "foo", :git => "#{lib_path('foo-1.0')}"
      G

      run <<-R
        require 'foo'
        puts FOO
      R
      expect(out).to eq("YES")
    end

    it "does not prompt to gem install if extension fails" do
      build_git "foo" do |s|
        s.add_dependency "rake"
        s.extensions << "Rakefile"
        s.write "Rakefile", <<-RUBY
          task :default do
            raise
          end
        RUBY
      end

      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gem "foo", :git => "#{lib_path('foo-1.0')}"
      G

      expect(out).to include("An error occurred while installing foo (1.0)")
      expect(out).not_to include("gem install foo")
    end
  end

  it "ignores git environment variables" do
    build_git "xxxxxx" do |s|
      s.executables = "xxxxxxbar"
    end

    Bundler::SharedHelpers.with_clean_git_env do
      ENV['GIT_DIR']       = 'bar'
      ENV['GIT_WORK_TREE'] = 'bar'

      install_gemfile <<-G, :exitstatus => true
        source "file://#{gem_repo1}"
        git "#{lib_path('xxxxxx-1.0')}" do
          gem 'xxxxxx'
        end
      G

      expect(exitstatus).to eq(0)
      expect(ENV['GIT_DIR']).to eq('bar')
      expect(ENV['GIT_WORK_TREE']).to eq('bar')
    end
  end

  describe "without git installed" do
    it "prints a better error message" do
      build_git "foo"

      install_gemfile <<-G
        git "#{lib_path('foo-1.0')}" do
          gem 'foo'
        end
      G

      bundle "update", :env => {"PATH" => ""}
      expect(out).to include("You need to install git to be able to use gems from git repositories. For help installing git, please refer to GitHub's tutorial at https://help.github.com/articles/set-up-git")
    end
  end
end
