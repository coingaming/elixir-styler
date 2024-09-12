# Copyright 2024 Adobe. All rights reserved.
# This file is licensed to you under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License. You may obtain a copy
# of the License at http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software distributed under
# the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
# OF ANY KIND, either express or implied. See the License for the specific language
# governing permissions and limitations under the License.

defmodule Styler.Style.ModuleDirectives.AliasLiftingTest do
  @moduledoc false
  use Styler.StyleCase, async: true

  test "does not lift aliases repeated >=2 times from 3 deep" do
    assert_style(
      """
      defmodule A do
        @moduledoc false

        @spec bar :: A.B.C.t()
        def bar do
          A.B.C.f()
        end
      end
      """,
      """
      defmodule A do
        @moduledoc false

        @spec bar :: A.B.C.t()
        def bar do
          A.B.C.f()
        end
      end
      """
    )
  end

  test "does not lifts from nested modules" do
    assert_style(
      """
      defmodule A do
        @moduledoc false

        defmodule B do
          @moduledoc false

          A.B.C.f()
          A.B.C.f()
        end
      end
      """,
      """
      defmodule A do
        @moduledoc false

        defmodule B do
          @moduledoc false

          A.B.C.f()
          A.B.C.f()
        end
      end
      """
    )
    end

  test "skips over quoted or odd aliases" do
    assert_style """
    alias Boop.Baz

    Some.unquote(whatever).Alias.bar()
    Some.unquote(whatever).Alias.bar()
    """
  end

  test "no deep nesting of an alias" do
    assert_style(
      """
      alias Foo.Bar.Baz

      Baz.Bop.Boom.wee()
      Baz.Bop.Boom.wee()

      """,
      """
      alias Foo.Bar.Baz

      Baz.Bop.Boom.wee()
      Baz.Bop.Boom.wee()
      """
    )
  end

  test "does not lift in modules with only-child bodies" do
    assert_style(
      """
      defmodule A do
        def lift_me() do
          A.B.C.foo()
          A.B.C.baz()
        end
      end
      """,
      """
      defmodule A do
        @moduledoc false
        def lift_me do
          A.B.C.foo()
          A.B.C.baz()
        end
      end
      """
    )
  end


  describe "comments stay put" do
    test "comments before alias stanza" do
      assert_style(
        """
        # Foo is my fave
        import Foo

        A.B.C.f()
        A.B.C.f()
        """,
        """
        # Foo is my fave
        import Foo

        A.B.C.f()
        A.B.C.f()
        """
      )
    end

    test "comments after alias stanza" do
      assert_style(
        """
        # Foo is my fave
        require Foo

        A.B.C.f()
        A.B.C.f()
        """,
        """
        # Foo is my fave
        require Foo

        A.B.C.f()
        A.B.C.f()
        """
      )
    end
  end

  describe "it doesn't lift" do
    test "collisions with configured modules" do
      Styler.Config.set!(alias_lifting_exclude: ~w(C)a)

      assert_style """
      alias Foo.Bar

      A.B.C
      A.B.C
      """

      Styler.Config.set!([])
    end

    test "collisions with std lib" do
      assert_style """
      defmodule DontYouDare do
        @moduledoc false

        My.Sweet.List.foo()
        My.Sweet.List.foo()
        IHave.MyOwn.Supervisor.init()
        IHave.MyOwn.Supervisor.init()
      end
      """
    end

    test "collisions with aliases" do
      for alias_c <- ["alias A.C", "alias A.B, as: C"] do
        assert_style """
        defmodule NuhUh do
          @moduledoc false

          #{alias_c}

          A.B.C.f()
          A.B.C.f()
        end
        """
      end
    end

    test "collisions with other lifts" do
      assert_style """
      defmodule NuhUh do
        @moduledoc false

        A.B.C.f()
        A.B.C.f()
        X.Y.C.f()
      end
      """

      assert_style """
      defmodule NuhUh do
        @moduledoc false

        A.B.C.f()
        A.B.C.f()
        X.Y.C.f()
        X.Y.C.f()
      end
      """
    end

    test "collisions with submodules" do
      assert_style """
      defmodule A do
        @moduledoc false

        A.B.C.f()

        defmodule C do
          @moduledoc false
          A.B.C.f()
        end

        A.B.C.f()
      end
      """
    end

    test "quoted sections" do
      assert_style """
      defmodule A do
        @moduledoc false
        defmacro __using__(_) do
          quote do
            A.B.C.f()
            A.B.C.f()
          end
        end
      end
      """
    end

    test "collisions with other callsites :(" do
      # if the last module of a list in an alias
      # is the first of any other
      # do not do the lift of either?
      assert_style """
      defmodule A do
        @moduledoc false

        foo
        |> Baz.Boom.bop()
        |> boop()

        Foo.Bar.Baz.bop()
        Foo.Bar.Baz.bop()
      end
      """

      assert_style """
      defmodule A do
        @moduledoc false

        Foo.Bar.Baz.bop()
        Foo.Bar.Baz.bop()

        foo
        |> Baz.Boom.bop()
        |> boop()
      end
      """
    end
  end
end
