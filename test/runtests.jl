using Test, JLLPrefixes, Base.BinaryPlatforms, Pkg
using JLLPrefixes: PkgSpec

@testset "JLL collection" begin
    function check_zstd_jll(zstd_pkgspec, zstd_artifacts)
        # Ensure this pkgspec is named Zstd_jll
        @test zstd_pkgspec.name == "Zstd_jll"

        # It only had one artifact to download, and it exists
        @test length(zstd_artifacts) == 1
        @test isdir(zstd_artifacts[1])
        @test isfile(joinpath(zstd_artifacts[1], "include", "zstd.h"))
    end

    @testset "Zstd_jll (native)" begin
        # Start with a simple JLL with no dependencies
        artifact_paths = collect_artifact_paths(["Zstd_jll"]; verbose=true)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)
    end

    # Do another simple JLL installation, but this time for a few different architectures
    for platform in [Platform("aarch64", "linux"), Platform("x86_64", "macos"), Platform("i686", "windows")]
        @testset "Zstd_jll ($(platform))" begin
            artifact_paths = collect_artifact_paths(["Zstd_jll"]; platform)
            check_zstd_jll(first(artifact_paths)...)

            # Test that we're getting the kind of dynamic library we expect
            artifact_dir = first(first(values(artifact_paths)))
            if os(platform) == "windows"
                libdir = "bin"
                libname = "libzstd-1.dll"
            elseif os(platform) == "macos"
                libdir = "lib"
                libname = "libzstd.1.dylib"
            else
                libdir = "lib"
                libname = "libzstd.so.1"
            end
            @test isfile(joinpath(artifact_dir, libdir, libname))
        end
    end

    # Test that we can request a particular version of Zstd_jll
    linux64 = Platform("x86_64", "linux")
    @testset "Zstd_jll ($(linux64), v1.4.2)" begin
        artifact_paths = collect_artifact_paths([PkgSpec(;name="Zstd_jll", version=v"1.4.2")]; platform=linux64)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)

        # Ensure that this is actually version 1.4.2
        artifact_dir = first(first(values(artifact_paths)))
        @test isfile(joinpath(artifact_dir, "lib", "libzstd.so.1.4.2"))
    end

    # Kick it up a notch; start involving dependencies
    @testset "XML2_jll ($(linux64), dependencies)" begin
        # Lock XML2_jll to v2.9 in case it adds more dependencies in the future
        artifact_paths = collect_artifact_paths([PkgSpec(;name="XML2_jll", version=v"2.9.12")]; platform=linux64)

        @test length(artifact_paths) == 3
        @test sort([p.name for p in keys(artifact_paths)]) == ["Libiconv_jll", "XML2_jll", "Zlib_jll"]
    end

    # Install two packages that have nothing to do with eachother at the same time
    @testset "Bzip2_jll + Zstd_jll" begin
        artifact_paths = collect_artifact_paths(["Bzip2_jll", "Zstd_jll"])
        @test length(artifact_paths) == 2
        @test sort([p.name for p in keys(artifact_paths)]) == ["Bzip2_jll", "Zstd_jll"]
    end

    # Test stdlibs across versions.  Note that `GMP_jll` was _not_ a standard library in v1.5,
    # it _is_ a standard library in v1.6 and v1.7.  Further note that beacuse it had no valid
    # mapping for aarch64-apple-darwin in Julia v1.5, these tests fail for that version on that
    # platform; we skip that version in thiat case.  I consider this something of a Pkg bug,
    # since we are resolving for x86_64-linux-gnu
    GMP_JULIA_VERSIONS = [
        ("10.3.2", v"1.5"),
        ("10.4.0", v"1.6"),
        ("10.4.1", v"1.7"),
        ("10.4.1", v"1.8"),
    ]
    if platforms_match(HostPlatform(), Platform("aarch64", "macos"))
        filter!(GMP_JULIA_VERSIONS) do (gmp_version, julia_version)
            return julia_version >= v"1.6"
        end
    end
    for (GMP_soversion, julia_version) in GMP_JULIA_VERSIONS
        @testset "GMP_jll (Julia $(julia_version))" begin
            artifact_paths = collect_artifact_paths(["GMP_jll"]; platform=Platform("x86_64", "linux"; julia_version))
            @test length(artifact_paths) == 1
            gmp_artifact_dir = only(first(values(artifact_paths)))
            @test isfile(joinpath(gmp_artifact_dir, "lib", "libgmp.so.$(GMP_soversion)"))
        end
    end

    # Test "impossible" situations via `julia_version == nothing`
    @testset "Impossible Constraints" begin
        # We can't naively install OpenBLAS v0.3.13 and LBT v5.1.1, because those are
        # from conflicting Julia versions, and the Pkg resolver doesn't like that
        for julia_version in (v"1.7.3", v"1.8.0")
            @test_throws Pkg.Resolve.ResolverError collect_artifact_paths([
                PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
                PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
            ]; platform=Platform("x86_64", "linux"; julia_version))
        end

        # So we must pass julia_version == nothing, as is the case in our `linux64` object
        artifact_paths = collect_artifact_paths([
            PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
            PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
        ]; platform=linux64)
        @test length(artifact_paths) == 3
        @test sort([p.name for p in keys(artifact_paths)]) == ["CompilerSupportLibraries_jll", "OpenBLAS_jll", "libblastrampoline_jll"]
    end

    # Test adding something that doesn't exist on a certain platform
    @testset "Platform Incompatibility" begin
        @test_logs (:warn, r"Dependency Libuuid_jll does not have a mapping for artifact Libuuid for platform x86_64-apple-darwin") begin
            artifact_paths = collect_artifact_paths(["Libuuid_jll"]; platform=Platform("x86_64", "macos"), verbose=true)
            @test isempty(artifact_paths)
        end
    end
end

exe = ""
if Sys.iswindows()
    exe = ".exe"
end

@testset "FFMPEG installation test" begin
    artifact_paths = collect_artifact_paths(["FFMPEG_jll"])
    installer_strategies = Dict(
        "copy" => copy_artifact_paths,
        "symlink" => symlink_artifact_paths,
        "hardlink" => hardlink_artifact_paths,
    )
    for strategy in keys(installer_strategies)
        mktempdir() do prefix
            @testset "$strategy strategy" begin
                installer_strategies[strategy](prefix, artifact_paths)

                # Ensure that a bunch of tools we expect to be installed are, in fact, installed
                for tool in ("ffmpeg", "bzcat", "fc-cache", "iconv", "x264", "x265", "xslt-config")
                    # Use `@eval` here so the test itself shows the tool name, for easier debugging
                    tool_name = string(tool, exe)
                    @eval @test isfile(joinpath($(prefix), "bin", $(tool_name)))

                    # Extra `abspath()` here to explicitly test dereferencing symlinks
                    @eval @test isfile(abspath(joinpath($(prefix), "bin", $(tool_name))))
                end

                # Symlinking is insufficient for RPATH, unfortunately.
                if strategy != "symlink"
                    run(`$(joinpath(prefix, "bin", "ffmpeg$(exe)")) -version`)
                end
            end
        end
    end
end
