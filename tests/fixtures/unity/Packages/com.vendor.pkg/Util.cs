// Embedded package source: it only compiles inside Unity, where UnityEngine and its defines exist
namespace Vendor.Pkg
{
    public static class Util
    {
        public static int Double(int a) => UnityOnly.Engine.Twice(a);
    }
}
