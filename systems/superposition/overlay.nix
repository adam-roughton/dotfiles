final: prev:
{
  vim-full = prev.vim-full.override {
    guiSupport = "no";
    darwinSupport = true;
  };
  hatch = prev.hatch.overridePythonAttrs { 
    doCheck = false;
  };

  # Downgrade to 0.2.10 while this is sorted: https://github.com/Azure/kubelogin/pull/719
  kubelogin = prev.kubelogin.override {
    buildGoModule = prevArgs: prev.buildGoModule(prevArgs // rec {
      version = "0.2.10";
      src = prev.fetchFromGitHub {
        owner = "Azure";
        repo = "kubelogin";
        rev = "v${version}";
        sha256 = "sha256-pi2dzIf48mqD3S7QqaZZ5sgcgPRtQZ10KpfojLVYCZA=";
      };
      vendorHash = "sha256-tuqWg7z9YJygEW3XwBXDwXHUNwaJeTAxRS1xv6bQpj4=";
    }); 

  };
  
  zbar = prev.zbar.overrideAttrs {
    doCheck = false; 
  };
}
