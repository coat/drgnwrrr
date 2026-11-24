{
  description = "a stripped down version of the NES classic";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          # What `zig build -Dandroid` asks for (see addAndroid in build.zig).
          androidSdk =
            (pkgs.androidenv.composeAndroidPackages {
              cmdLineToolsVersion = "20.0";
              platformToolsVersion = "37.0.3";
              buildToolsVersions = ["36.1.0"];
              platformVersions = ["35"]; # Android 15
              ndkVersions = ["29.0.14206865"];
              includeNDK = true;
              includeEmulator = false;
              includeSystemImages = false;
              includeSources = false;
            }).androidsdk;
        in {
          devShells.${system}.default = pkgs.mkShell {
            ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
            JAVA_HOME = pkgs.jdk17.home;

            packages = with pkgs;
              [
                zig_0_17
                sdl3
                androidSdk
                jdk17
                zip # zig build portmaster-zip
              ]
              ++ (pkgs.lib.optionals stdenv.hostPlatform.isLinux [kcov]);
          };

          formatter.${system} = pkgs.alejandra;
        }
      )
      systems
    );
}
