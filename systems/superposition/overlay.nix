final: prev:
{
  vim_configurable = prev.vim_configurable.override {
    guiSupport = "no";
    darwinSupport = true;
  };
}
