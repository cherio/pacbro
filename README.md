SCREENSHOTS

![pacbro-w-comments](https://github.com/cherio/pacbro/assets/2200569/ca7e612e-f451-4fdf-8e16-733ad979eb8c)
![pacbro-files](https://github.com/cherio/pacbro/assets/2200569/738f8450-bf49-4d15-a532-e9a92d37d418)

SYNOPSIS

    pacbro.pl [--aur]

DESCRIPTION

    This is terminal based package browser for Arch Linux
    with extensive filtering capabilities.

OPTIONS

    --aur
        Include AUR packages. Package loading and navigation are
        slower as the information is fetched via web lookups

    --help | -h
        help! I need somebody!

ABOUT

    The main list on the left displays the loaded list of packages.
    If can be filtered by either package name typed into the
    search box on the top of the list, or with one of canned
    filters described below. The list is assembled with the help
    of "pacman"; AUR web API is used to get package information
    from AUR repo if launched with the "--aur" option.

    The top panel displays package information.

    The bottom panels display:
    * related package lists: dependencies, dependants, conflicts etc;
      package navigation within those lists is supported.
    * list of files installed from the package; file preview is
      supported
    The contents of these panels can be chosen via main menu or
    key bindings

    The following common single/multiple choice filters available:
    * By repository
    * By installation type (Explicit/As Dependency)
    * By "outdated" status
    * By file path provided by the installed package (RegEx)
    * By package details (RegEx)

    This program does not have package management capabilities
    (not yet) and can run as any unprivileged user.

    This program extensively relies upon "tmux" multi-panel layout
    and "fzf" list management. A small subset of keybindings were
    redefined, but the rest of tmux keys should work as locally
    configured; those having experience working in tmux should find
    themselves in a familiar environment.

    Fun fact: pacbro.pl was tested to fit and run in 80x24 green
    text terminal, although I hope you have a bigger screen.

DEPENDENCIES

    This program relies on the following utilities:
    * perl: this program is a perl script
    * tmux: multi-pane terminal interface with resizable areas
    * fzf: used for displaying various lists and option dialogs
    * less: for simple text viewing
    * pacman: reads package information
    * bash: readline based regex filter input
    * coreutils: shell scripting glue

AUR

    For AUR packages to be loaded, "--aur" argument must passed to this
    program. Without "--aur" the packages installed from it will be
    classified as in "~foreign" repository.

    It is impractical to load details of all packages in AUR,
    there are just too many of them. This means context search by
    package details (e.g. by file name or package description) doesn't
    work for AUR packages, unless they are installed.

KEYBINDINGS

    Main screen keebindings

    Ctrl+c      Exit pacbro
    Alt+q       Exit pacbro
    Alt+Left    Back in package view history
    Alt+Right   Forward in package view history
    Ctrl+Left   Focus pane 🠜
    Ctrl+Up     Focus pane 🠝
    Ctrl+Down   Focus pane 🠟
    Ctrl+Right  Focus pane 🠞
    Alt+x       Tag/Mark current package (toggle)
    Alt+v       Detail View/Layout (Alt+v)
    Alt+r       Repo filter (Alt+r)
    Alt+i       Installed status filter (Alt+i)
    Alt+o       Outdated status filter (Alt+o)
    Alt+f       Search filenames (Alt+f)
    Alt+d       Search package details (Alt+d)
    Alt+t       Toggle "Show Tagged" packages (Alt+t)
    Alt+m       Main Menu (Alt+m)
    Alt+k       Keyboard Shortcuts (Alt+k)
    Alt+?       Help / About (Alt+?)

    In list/selection popup dialogs:

    Alt+q       Exit list popup
    Ctrl+a      Select all in multiselect dialogs (fzf)
    Tab         Toggle select in multiselect lists (fzf)

