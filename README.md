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

    The top panel displays one of the following:
    * package information fetched with pacman -Qi|-Si
    * selected package file contents or type

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

    Fun fact: it was tested to fit and run in 80x24 green text
    terminal, although I hope you have a better screen.

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

    For AUR packages to be loaded, "--aur" argument passed to this
    program.

    It is impractical to load details of all packages in AUR,
    there are just too many of them. This means search by package
    details doesn't work for not installed AUR packages.

    For the same reason auto display of package details is disabled,
    when AUR listing is on. You need to explicitly hit <Enter> on
    the package in order to fetch package details from the web.

KEYBINDINGS

    Main screen keebindings

    Ctrl+c	Exit pacbro
    Alt+q	Exit pacbro
    Alt+Left	Back in package view history
    Alt+Right	Forward in package view history
    Ctrl+Left	Focus pane 🠜
    Ctrl+Up	Focus pane 🠝
    Ctrl+Down	Focus pane 🠟
    Ctrl+Right	Focus pane 🠞
    Alt+v	Detail View/Layout
    Alt+r	Repo filter
    Alt+i	Installed status filter
    Alt+o	Outdated status filter
    Alt+f	Search filenames
    Alt+d	Search package details
    Alt+m	Main Menu
    Alt+k	Keyboard Shortcuts
    Alt+?	Help / About

    In list/selection popup dialogs:

    Alt+q	Exit list popup
    Ctrl+a	Select all (multiselect dialogs)

