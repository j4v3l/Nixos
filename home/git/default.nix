{ vars, ... }:

{
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = vars.gitUser;
        email = vars.email;
      };

      init.defaultBranch = "main";

      pull.rebase = false;
    };
  };
}
