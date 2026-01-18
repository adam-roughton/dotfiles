final: prev:
{
  vim-full = prev.vim-full.override {
    guiSupport = "no";
    darwinSupport = true;
  };
  hatch = prev.hatch.overridePythonAttrs { 
    doCheck = false;
  };
  zbar = prev.zbar.overrideAttrs {
    doCheck = false; 
  };
}
