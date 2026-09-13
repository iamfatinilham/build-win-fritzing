@{
    # Deliberately small profile: values that are not declared by Fritzing's
    # qmake files belong here. Versioned libraries declared by Fritzing are
    # read from the checked-out source by Get-FritzingBuildContract.ps1.
    SchemaVersion = 1
    ZlibVersion = '1.3.2'

    # Some upstream CMake projects still declare policies older than CMake 4.
    # Keep this explicit so a hosted-runner image upgrade cannot silently
    # change the compatibility policy used for a release.
    CMakePolicyVersionMinimum = '3.10'
}
