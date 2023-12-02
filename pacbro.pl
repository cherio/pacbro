#!/usr/bin/perl
#
# Arch package browser
#

use strict;
use warnings;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case);
use Time::HiRes;
use POSIX;

(`tty` =~ m{^/dev/} && $ENV{TERM}) || die("Must run in terminal\n");
my $tmux_exe = exe_path('tmux') // die("Please install tmux\n");
my $fzfx = exe_path('fzf') // die("Please install fzf\n");
# my $yayx = exe_path('yay');
my $progname = ($0 =~ m{(?:^|/)([^/]+?)(?:\.\w+)?$}s) ? $1 : die("Bad program name: $0\n");
my $work_dir = "/tmp/$progname-$ENV{USER}";
my $sess_code = "$progname-$$";
my $tumx_cmd = "$tmux_exe -L $sess_code";
my $log_fname = "$work_dir/app.log"; # global log
my $path_pfx = "$work_dir/$sess_code";

Getopt::Long::GetOptions(
	'aur' => \(my $use_aur),
	'help|h' => \(my $show_help),
);

# die("Install 'yay' to use AUR feature\n") if $use_aur && !$yayx;

my $shutdown_hooks = [];
my $layout_list = [
	{ code => '1', short => 'Files', list_names => ['Package Files'] },
	{ code => '2', short => 'DepOn/ReqBy', list_names => ['Depends On', 'Required By'] },
	{ code => '3', short => 'Opt Dep/For', list_names => ['Optional Deps', 'Optional For'] },
	{ code => '4', short => 'Make/Check', list_names => ['Make Deps', 'Check Deps'] },
	{ code => '5', short => 'Prov/Confl', list_names => ['Provides', 'Conflicts With'] },
	{ code => '6', short => 'Prov/Repl', list_names => ['Provides', 'Replaces'] },
];

for my $layout_item (@$layout_list) {
	$layout_item->{label} //= join(' / ', @{$layout_item->{list_names}});
}

my $pac_inst_states = [
	{ code => 'E', label => 'Explicitly Installed', short => 'explicit' },
	{ code => 'I', label => 'Installed as Dependency', short => 'as dep' },
	{ code => 'N', label => 'Not Installed', short => 'not inst' }
];

my $outdated_states = [
	{ code => '', label => 'Do not filter', short => '*' },
	{ code => 'O', label => 'Installed, Outdated', short => 'outdated' },
	{ code => 'U', label => 'Installed, Up-to-date', short => 'up-to-date' },
];

my $cmd_map = { # commands sent back to pacbro from tmux windows, fzf, less, etc
	QUIT => sub { exit(0) },
	PANREADY => \&pipcmd_PANREADY,
	TMUXUP => \&pipcmd_TMUXUP,
	KEYPRESS => \&pipcmd_KEYPRESS,
	PACNAV => \&pipcmd_PACNAV,
	WINRESZ => \&tmux_layout_render,
	PANFOCUSIN => \&pipcmd_PANFOCUSIN,
	PANFOCUSOUT => \&pipcmd_PANFOCUSOUT,
	PACFLT => \&pipcmd_PACFLT,
}; # each handler gets 2 args: global tmux object & command code

my $tmux_key_list = [
	{ key => 'C-c', foo => sub {exit(0)}, label => 'Exit pacbro' },
	{ key => 'M-q', foo => sub {exit(0)}, label => 'Exit pacbro' },
	{ key => 'M-Left', foo => sub {package_navigate($_[0], -1)}, label => 'Back in package view history' },
	{ key => 'M-Right', foo => sub {package_navigate($_[0], 1)}, label => 'Forward in package view history' },
	{ key => 'C-Left', foo => \&move_to_pane, label => 'Focus pane 🠜', arg => '-L' }, #
	{ key => 'C-Up', foo => \&move_to_pane, label => 'Focus pane 🠝', arg => '-U' },
	{ key => 'C-Down', foo => \&move_to_pane, label => 'Focus pane 🠟', arg => '-D' },
	{ key => 'C-Right', foo => \&move_to_pane, label => 'Focus pane 🠞', arg => '-R' },
];

my $pac_hist_nav_keys = []; # key, dir, label, foo

my $app_menu_list = [
	{ code => "LAYOUT", label => 'Detail View/Layout', key => 'M-v', popper => \&menu_list_popper, handler => \&tmux_layout, multi => 0, list => $layout_list },
	{ code => "REPOFILTER", label => 'Repo filter', key => 'M-r', popper => \&menu_list_popper, handler => \&repo_filter, multi => 1 },
	{ code => "INSTFILTER", label => 'Installed status filter', key => 'M-i', popper => \&menu_list_popper, handler => \&inst_filter, multi => 1, list => $pac_inst_states },
	{ code => "OUTDATED", label => 'Outdated status filter', key => 'M-o', popper => \&menu_list_popper, handler => \&outdated_filter, multi => 0, list => $outdated_states },
	{ code => "rxf", label => 'Search filenames', key => 'M-f', popper => \&menu_popper_rx_filter }, # , flt => 'frx'
	{ code => "rxd", label => 'Search package details', key => 'M-d', popper => \&menu_popper_rx_filter }, # , flt => 'drx'
	{ code => "MAINMENU", label => 'Main Menu', key => 'M-m', popper => \&menu_list_popper, handler => \&high_level_menu_action, multi => 0 },
	{ code => "RPTDEPERR", label => 'Find dependency issues (not implemented)', popper => \&menu_report }, # cycles, missing deps
	{ code => "RPTUNNEEDED", label => 'Find not needed (not implemented)', popper => \&menu_report }, # only dependencies, including cycles
	{ code => "KEYMAP", label => 'Keyboard Shortcuts', key => 'M-k', popper => \&menu_keymap },
	{ code => "ABOUT", label => 'Help / About', key => 'M-?', popper => \&menu_about },
];

my $app_menu_map = {};
for my $menu (@$app_menu_list) {
	$app_menu_map->{$menu->{code}} = $menu;
	if ($menu->{key}) {
		push(@$tmux_key_list, { key => $menu->{key}, foo => sub { $menu->{popper}->($_[0], $menu) }, label => $menu->{label}, menu => $menu });
	}
	$cmd_map->{$menu->{code}} = sub { menu_handle_response($_[0], $menu, $_[1]) }; # add commands for menu items
}
$app_menu_map->{MAINMENU}->{list} = $app_menu_list;

# create files for each pane
my $tmux_pan_list = [
	{ code => 'main', label => 'Main package list' },
	{ code => 'info', label => 'Package info' },
	{ code => 'botl', label => 'Detail list 1' },
	{ code => 'botr', label => 'Detail list 2' },
];

# Global state
my $tmux = {
	layout => $layout_list->[0],
	hist => { arr => [] },
	flt => {},
	pans => { map {$_->{code} => $_} @$tmux_pan_list }, # panes: main | [info / [botl | botr]]
	cmd_in => "$path_pfx.fifo", # communication from tmux
	pac0 => {name => '', info_text => '', info => {}},
};

-d $work_dir || mkdir($work_dir) || die("Could not create work dir: $work_dir\n");

for my $pan (@$tmux_pan_list) {
	$pan->{file} = "$path_pfx.p.$pan->{code}";
	write_file($pan->{file}, '');
}

# Global environment variables
$ENV{SHELL} = "/bin/sh";
$ENV{FZF_DEFAULT_OPTS} = "--reverse";

# prepare key map
my $tmux_key_map = {map {$_->{key} => $_} @$tmux_key_list};

$show_help && do{ print(help()); exit(0); };
tmux_start($tmux);

while (my $msg = pacbro_next_input_cmd($tmux)) {
	$msg =~ m/^([\w\-]+)(?:[ ]+(.*))?$/m || do{ report("Bad command: '$msg'"); next };
	# report("MSG queue: $msg");
	my ($code, $detail) = (uc($1), $2);
	my $cmd_sub = $cmd_map->{$code};
	defined($cmd_sub) ? $cmd_sub->($tmux, $detail) : report("Unknown: $msg");
}

exit 0;

END {
	tmux_exit_cleanup($tmux //= {});
	# generic cleanup
	defined($shutdown_hooks) && do { while ($_ = pop(@$shutdown_hooks)) { $_->() } };
}

# TMUX =============================

sub tmux_start {
	my ($tmux) = @_;

	report("starting sess: $sess_code");
	my $cmd_in = $tmux->{cmd_in};
	POSIX::mkfifo($cmd_in, oct(700));
	my $ctl_proc_fid = "/proc/$$";

	my $tpid = fork();
	if ($tpid == 0) {
		# lesskey codes can be checked as: cat -vte
		write_file("$work_dir/lesskey.main", "q invalid\n"); # alt+q to exit less
		write_file("$work_dir/lesskey.pop", "^q quit\n^[q quit\nq quit\n"); # alt+q to exit less
		my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --lesskey-src='$work_dir/lesskey.main'";
		my $info_cmd = "echo PANREADY info \\\$TMUX_PANE >> $cmd_in; while : ; do $less_cmd $tmux->{pans}->{info}->{file}; done";

		my $main_file = $tmux->{pans}->{main}->{file};
		my $sel_action = "execute-silent(echo PACNAV {} >> $tmux->{cmd_in})";
		my $binds = "--bind enter:'$sel_action' --bind double-click:'$sel_action'";
		$binds .= " --bind left-click:'$sel_action'";
		# $binds .= " --bind focus:'$sel_action'" if !$use_aur; # do not auto-load package info
		$binds .= " --bind 'ctrl-alt-r:reload(cat $main_file)'";
		$binds .= " --bind 'load:first'";
		$binds .= " --bind 'start:unbind(ctrl-c,ctrl-g,ctrl-q,esc)'"; # do not allow exiting keys
		my $pane_fzf = "cat $main_file 2>/dev/null | $fzfx --cycle -e $binds";
		my $main_cmd = "echo PANREADY main \\\$TMUX_PANE >> $cmd_in; while : ; do $pane_fzf; done";

		exec("$tumx_cmd " .
			"set -g status-left ''" . ' \; ' .
			"set -g status-right ''" . ' \; ' .
			"set -g window-status-current-format ''" . ' \; ' .
			"set -g default-shell $ENV{SHELL}" . ' \; ' .
			"set -g pane-active-border-style 'bg=grey'" . ' \; ' .
			"set -g pane-border-lines double" . ' \; ' .
			"set -g focus-events on" . ' \; ' .
			qq`new-session -s $sess_code -n main "$main_cmd"` . ' \; ' .
			qq`split-window -h -l 66\% "$info_cmd"` . ' \; ' .
			qq`split-window -v ${\( cmd_arg(fzf_pane_cmd($tmux, 'botl')) )}` . ' \; ' .
			" >/dev/null 2>>'$log_fname' ; " .
			# in case tmux is killed, send QUIT to the main process and run cleanup just in case
			# "[ -p '$cmd_in' ] && echo QUIT >> '$cmd_in'"
			"[ -p '$cmd_in' ] && [ -d $ctl_proc_fid ] && perl -e 'alarm 2; sysopen(FH, q|$cmd_in|, Fcntl::O_WRONLY|Fcntl::O_APPEND) and CORE::say FH q|QUIT|' ;" .
			"rm -f $path_pfx.*"
		) or do {
			$tmux = {};
			die("Failed to launch tmux $!\n");
		};
		exit(1);
	}

	report("tmux PID: $tpid");
	$tmux->{tpid} = $tpid;
}

sub fzf_pane_cmd {
	my ($tmux, $pane_code, $fzf_args) = @_;
	my $file = $tmux->{pans}->{$pane_code}->{file};
	my $tit_file = "$file.title";
	my $sel_action = "execute-silent(echo PACNAV {} >> $tmux->{cmd_in})";
	my $binds = "--bind enter:'$sel_action' --bind double-click:'$sel_action'";
	$binds .= " --bind 'ctrl-alt-r:reload(cat ${\(cmd_arg($file))})'";
	$binds .= " --bind 'ctrl-alt-t:transform-query(cat ${\(cmd_arg($tit_file))})'";
	$binds .= " --bind 'start:unbind(ctrl-c,ctrl-g,ctrl-q,esc)'"; # do not allow exiting keys
	$binds .= " --bind 'start:reload(cat ${\(cmd_arg($file))})'";
	$binds .= " --bind 'start:transform-query(cat ${\(cmd_arg($tit_file))})'";
	$binds .= " --bind 'change:transform-query(cat ${\(cmd_arg($tit_file))})'";
	$binds .= " --bind 'load:first'";
	my $pane_fzf = "cat '$file' 2>/dev/null | $fzfx --disabled --no-info --prompt='' $binds ".($fzf_args // '');
	return "echo PANREADY $pane_code \$TMUX_PANE >> '$tmux->{cmd_in}'; while : ; do $pane_fzf; done";
}

sub pipcmd_PANREADY {
	my ($tmux, $detail) = @_;
	$detail || report("PANREADY command is missing details", 1);
	my ($pane_name, $pane_id) = ($detail =~ m/^(\S+)\h+(\S+)$/) ? ($1, $2) :
		report("PANREADY command details is invalid: $detail", 1);
	report("PANREADY $pane_name, $pane_id");
	my $pans = $tmux->{pans};
	$pans->{$pane_name}->{id} = $pane_id;
	if (!$tmux->{ready}) {
		$tmux->{ready} = scalar(grep {!$pans->{$_}->{id}} qw/main info botl/) ? 0 : 1;
		$tmux->{ready} && system("echo TMUXUP >> $tmux->{cmd_in} &");
	}
}

sub pipcmd_TMUXUP {
	my ($tmux, $detail) = @_;

	$tmux->{comm_h} //= do {#
		my $control_output = "/dev/null"; # "$path_pfx.control";
		open(my $tmux_comm_h, '|-', "$tumx_cmd -C attach -t $sess_code >$control_output") or report("Could not launch control mode", 1);
		$tmux_comm_h->autoflush();
		$tmux->{comm} = sub {
			print $tmux_comm_h $_[0]."\n"
		};
		report("COMM set");
		$tmux_comm_h
	};

	$tmux->{comm}->("bind-key -n C-q kill-window");
	for my $key (keys %$tmux_key_map) {
		$tmux->{comm}->(qq`bind-key -n '$key' run 'echo "KEYPRESS $key" >> $tmux->{cmd_in}'`);
	}

	#$tmux->{comm}->(qq`set-hook -w window-resized "run 'echo WINRESZ >> $tmux->{cmd_in}'"`);
	for my $pan (@$tmux_pan_list) {
		#$tmux->{comm}->(qq`set-hook -p -t $pan->{id} pane-focus-in "run 'echo PANFOCUSIN $pan->{code} >> $tmux->{cmd_in}'"`);
	}
	#my $pan_info = $tmux->{pans}->{info};
	#$tmux->{comm}->(qq`set-hook -p -t $pan_info->{id} pane-focus-out "run 'echo PANFOCUSOUT $pan_info->{code} >> $tmux->{cmd_in}'"`);

	pac_db_load_full($tmux) if !$tmux->{db};
	pac_list_load($tmux);
	tmux_layout_render($tmux);
}

sub pipcmd_KEYPRESS {
	my ($tmux, $key) = @_;
	report("KEYPRESS: $key");
	($_ = $tmux_key_map->{$key}) && return $_->{foo}->($tmux, $_);
	tmux_status_notify($tmux, "Unconfigured key: $key");
	report("Unconfigured key: $key");
}

sub tmux_exit_cleanup {
	my ($tmux) = @_;
	($_ = delete($tmux->{comm_h})) && close($_);
	$::{session_is_down}++ || system("$tumx_cmd kill-session -t $sess_code 2>/dev/null");
	($_ = delete($tmux->{tpid})) && do { waitpid($_, 4) == -1 && kill('KILL', $_); };
	$::{session_files_rm}++ || system("rm -f $path_pfx.*");
}

sub pacbro_next_input_cmd {
	my ($tmux) = @_;
	my $from_tmux = $tmux->{from_tmux};
	if (defined($from_tmux) && scalar(@$from_tmux)) {
		return pop(@$from_tmux);
	}
	while ($tmux->{cmd_in}) {
		if (my $msgs_text = run_blocking(1, sub { read_file($tmux->{cmd_in}, 1) })) {
			my @lines = ($msgs_text =~ m/\V+/gs);
			$tmux->{from_tmux} = scalar(@lines) ? \@lines : next;
			return pacbro_next_input_cmd($tmux);
		}
		waitpid($tmux->{tpid}, WNOHANG) && report("tmux exited, bye", 0); # tmux exited
		-e $tmux->{cmd_in} || report("feedback pipe kaput, bye", 0); # communication pipe is gone
	}
}

sub move_to_pane {
	my ($tmux, $key_item) = @_;
	$tmux->{comm}->("select-pane $key_item->{arg}");
}

sub package_navigate {
	my ($tmux, $nav_cmd) = @_;

	my ($harr, $curr) = @{$tmux->{hist}}{qw/arr curr/};

	defined($curr) || return; # nowhere to go
	my $arrlen = scalar(@$harr);

	$curr += $nav_cmd;
	($curr < 0 || $curr < $arrlen - 20 || $curr >= $arrlen) &&
		return tmux_status_notify($tmux, "Out of history range: $curr/$arrlen");
	my $pac_nm = $harr->[$curr] //
		return tmux_status_notify($tmux, "Missing history at: $curr/$arrlen"); # no history
	my $pac = $tmux->{db}->{pac_map}->{$pac_nm} //
		return tmux_status_notify($tmux, "Package not found (NAV): $pac_nm/$curr/$arrlen");

	$tmux->{hist}->{curr} = $curr;
	package_sel($tmux, $pac);
}

sub pipcmd_PACNAV {
	my ($tmux, $pac_nm) = @_;
	defined($pac_nm) || do { tmux_status_notify($tmux, "Bad NAV: $pac_nm"); return };
	# report("NAV: $pac_nm");

	$pac_nm && $pac_nm =~ m{^/} && # is a simple file
		return file_sel($tmux, $tmux->{pac_file_sel} = $pac_nm);

	$pac_nm = $pac_nm =~ m/^([^\s\<\>\=]+)/ ? $1 : return tmux_status_notify($tmux, "Bad package spec: $pac_nm");

	my $pac = $tmux->{db}->{pac_map}->{$pac_nm} //
		return tmux_status_notify($tmux, "Package not found: $pac_nm");

	# save navigation history
	my $hist = $tmux->{hist};
	my ($harr, $curr) = @$hist{qw/arr curr/};
	$curr = !defined($curr) || $curr < -1 || $curr > 90 ? 0 : $curr + 1;
	$harr->[$curr] = $pac_nm;
	$#$harr = $curr if $#$harr > $curr;
	if ((my $arrlen = scalar(@$harr)) >= 40) {
		$hist->{arr} = $harr = [@$harr[$arrlen - 20 .. $arrlen]]; # exactly 20
	}
	$hist->{curr} = $#$harr;

	package_sel($tmux, $pac);
}


sub package_sel {
	my ($tmux, $pac) = @_;

	pac_fill_in_info($tmux, $pac);

	if (!($_ = $tmux->{pac}) || $_->{name} ne $pac->{name}) { # if package is different
		write_file("$tmux->{pans}->{info}->{file}", $pac->{info_text} // '');
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{info}->{id} g R");
	}
	$tmux->{pac} = $pac;
	my $pac_det_lists = pac_list_get($pac); # { list_name => multiline_text }

	my $layout = $tmux->{layout}; # depending on the layout
	my $list_names = $layout->{list_names};

	write_file("$tmux->{pans}->{botl}->{file}", $pac_det_lists->{$list_names->[0]} // '');
	$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-r'");

	if ($list_names->[1]) {
		write_file("$tmux->{pans}->{botr}->{file}", $pac_det_lists->{$list_names->[1]} // '');
		$tmux->{pans}->{botr}->{id} &&
			$tmux->{comm}->("send-keys -t $tmux->{pans}->{botr}->{id} 'C-M-r'");
	}
}

sub file_sel {
	my ($tmux, $file) = @_;
	-f $file || return;
	my $file_q = cmd_arg($file);
	my $less_pop = "less -X -~ -S -Q -P '~' --mouse --lesskey-src='$work_dir/lesskey.pop'";
	my $tmux_cmd_arg = "{ grep -IF '' $file_q || { file -b $file_q; stat $file_q; }; } | $less_pop";
	system("$tumx_cmd display-popup -h 100\% -w 100\% -E ".cmd_arg($tmux_cmd_arg)." &");
}

# LOADING / PARSING data

sub pac_list_load { # filter criteria changed - reload the list
	my ($tmux) = @_;
	my $pac_lst = ($tmux->{db} // die("pacman DB must be loaded here\n"))->{pac_lst};
	my $filterer = pac_filterer($tmux);

	my $pac_count = 0;
	open(my $pac_list_h, '>', $tmux->{pans}->{main}->{file})
		or die("Couldn't write to file $tmux->{pans}->{main}->{file}, $!\n");
	for my $pac (@$pac_lst) {
		$filterer->($pac) && next;
		my $pac_sfx = $pac->{inst} ? " [$pac->{ver_inst}".(($pac->{dated} // '') eq 'O' ? " < $pac->{ver_repo}" : '')."]" : '';
		print $pac_list_h $pac->{name}."$pac_sfx\n";
		$pac_count++;
	}
	close($pac_list_h);

	$tmux->{comm}->("send-keys -t $tmux->{pans}->{main}->{id} 'C-M-r'");
	$pac_count ?
		system(qq`echo PACNAV "\$(grep -Po -m1 '^\\S+' '$tmux->{pans}->{main}->{file}')" >> $tmux->{cmd_in} &`) :
		package_sel($tmux, $tmux->{pac0});
}

sub pac_filterer { # returns filter function
	my ($tmux) = @_;
	my $flt_repo = $tmux->{flt}->{repo} ? { map { $_ => 1 } ($tmux->{flt}->{repo} =~ m/\S+/gs) } : undef;
	my $flt_inst = $tmux->{flt}->{inst} // '';
	my $flt_dated = $tmux->{flt}->{dated} // '';
	my $flt_rxf = $tmux->{flt}->{rxf} // '';
	my $flt_rxd = $tmux->{flt}->{rxd} // '';
	return sub { # if returns "true" - the PAC is rejected
		defined($flt_repo) && !$flt_repo->{$_[0]->{repo_nm}} && return 1; # filter by REPO
		$flt_inst && index($flt_inst, $_[0]->{inst} // 'N') == -1 && return 1; # filter by INST
		$flt_dated && ($_[0]->{dated} // '') ne $flt_dated && return 1; # filter by OUTDATED
		$flt_rxf && ($_[0]->{file_list} // '') !~ m/$flt_rxf/m && return 1;
		$flt_rxd && ($_[0]->{info_text} // '') !~ m/$flt_rxd/m && return 1;
	}
}

sub pac_db_load_full {
	my ($tmux) = @_;

	my ($repo_map, $repo_lst, $pac_map, $pac_lst) = ({}, [], {}, []);
	my ($stat_db_s_cnt, $stat_db_q_cnt) = (0, 0, 0);

	$tmux->{comm}->("set window-status-current-format 'Loading package data ... '");

	report(timest(Time::HiRes::time()) . " will load packages now");

	my $pac_list_exe = $use_aur ? "(curl -sL https://aur.archlinux.org/packages.gz | gunzip | sed -e 's/^/aur /'; pacman -Sl)" : "pacman -Sl";
	open(my $pach, '-|', "$pac_list_exe | sort -k 2.1") or die("Couldn't load package info\n $!");
	while (<$pach>) {
		my ($repo_nm, $pac_nm) = m{^(\S++) (\S++)}s;
		if ($pac_map->{$pac_nm // next}) {
			$repo_nm eq 'aur' && next; # exclude AUR duplicates
			index($repo_nm, '-testing') != -1 && next; # testing repos enabled - use them
		}

		my $repo = ($repo_map->{$repo_nm} //= do {
			push(@$repo_lst, my $repo = {name => $repo_nm});
			$repo
		});

		# my $needs_upd = defined($ver_local);
		my $pac = {name => $pac_nm, repo_nm => $repo_nm};

		$pac_map->{$pac_nm} = $pac;
		push(@$pac_lst, $pac);
	}
	close($pach);

	report(timest(Time::HiRes::time()) . " loaded the -Sl list");
	#report("DATED stats: ".(join(' ', %$debug_stat)));
	# name, inst [EIN], repo_nm, repo, ver_inst, ver_repo, dated, info{}, pk_lists{}, info_text, file_list

	my $pacs_foreign = [];
	my $pacs_aur = [];

	{ # always load installed data
		local $/ = "\n\n"; # gulp large text blocks
		my $loaded_recs = 0;
		open(my $pacqh, '-|', 'pacman -Qi') or die("Couldn't load package info\n $!");
		while (my $rec_text = <$pacqh>) {
			my $pac_props = pac_props_parse($rec_text);
			my $pac = $pac_map->{$pac_props->{'Name'} // next};
			if (!$pac) {
				my $repo_nm = '~foreign';
				my $repo = ($repo_map->{$repo_nm} //= do {
					push(@$repo_lst, my $repo = {name => $repo_nm});
					$repo
				});
				$pac = {name => $pac_props->{'Name'}, repo_nm => $repo_nm};
				$pac_map->{$pac_props->{'Name'}} = $pac;
				push(@$pac_lst, $pac);
				push(@$pacs_foreign, $pac);
			} elsif ($pac->{repo_nm} eq 'aur') {
				push(@$pacs_aur, $pac->{name});
			}
			$pac->{ver_inst} = $pac_props->{'Version'};
			($_ = $pac_props->{'Install Reason'}) && ($pac->{inst} = substr($_, 0, 1)); # E|I
			$loaded_recs++;
			@$pac{qw/info info_text/} = ($pac_props, "--- Installed info ---\n" . $rec_text =~ s/\s*$/\n/sr);
		}
		report(timest(Time::HiRes::time()) . " loaded -Qi recs: $loaded_recs");
	}

	{ # Load Sync DB
		local $/ = "\n\n"; # gulp large text blocks
		#my $aur_cmd = (@$pacs_aur) ? "; yay -Si ".join(' ', @$pacs_aur) : '';
		my $aur_cmd = '';
		open(my $pacsh, '-|', "pacman -Si $aur_cmd") or die("Couldn't load package info\n $!");
		while (my $info_text = <$pacsh>) {
			my $pac_props = pac_props_parse($info_text);
			my $pac = $pac_map->{$pac_props->{'Name'}};
			pac_add_sync_info($pac, $info_text, $pac_props);
		}
		report(timest(Time::HiRes::time()) . " loaded -Si recs");
	}

	# load file list per PAC
	open(my $pacfh, '-|', 'pacman -Ql') or die("Couldn't load package info\n $!");
	my ($pac_name_prev, $pac_files_prev) = ('', '');
	while (my $rec_text = <$pacfh>) {
		my ($pac_name, $pac_file) = ($rec_text =~ m/^([^\ \n]+) (.+)/s);
		if ($pac_name eq $pac_name_prev) {
			$pac_files_prev .= $pac_file;
		} else {
			($_ = $pac_map->{$pac_name_prev}) && ($_->{file_list} = $pac_files_prev);
			($pac_name_prev, $pac_files_prev) = ($pac_name, $pac_file);
		}
	};
	($_ = $pac_map->{$pac_name_prev}) && ($_->{file_list} = $pac_files_prev);

	report(timest(Time::HiRes::time()) . " loaded -Ql file list");

	$tmux->{comm}->("set window-status-current-format ''");
	$app_menu_map->{REPOFILTER}->{list} = [sort map {$_->{name}} @$repo_lst];

	return $tmux->{db} = {repo_map => $repo_map, repo_lst => $repo_lst, pac_map => $pac_map, pac_lst => $pac_lst};
}

sub pac_props_parse {
	my ($rec_text) = @_;
	my $pac_info = {}; # parsed map and some derived value
	while ($rec_text =~ m/^(\w+(?:[ \-]+\w+)*)[ ]*\:[ ]*(\S.*?)(?=\v[\w\v]|\v*\z)/mgs) {
		$pac_info->{$1} = $2;
	}
	return $pac_info;
}

sub pac_list_get {
	my ($pac) = @_;
	($_ = $pac->{pk_lists}) && return $_;

	my $list_prop_list = ($::{pac_list_prop_list} //=
		['Depends On', 'Required By', 'Optional Deps', 'Optional For', 'Make Deps', 'Check Deps', 'Provides', 'Conflicts With', 'Replaces']);

	my $pac_info = $pac->{info};
	my $pk_lists = {};

	for my $list_code (@$list_prop_list) {
		my $list_text = $pac_info->{$list_code} // next;
		if ($list_text eq 'None') {
			$list_text = '';
		} else {
			if ($list_code eq 'Optional Deps') {
				$list_text =~ s/:[^\n]*//gs;
				$list_text =~ s/\[[Ii]nstalled\]//gs;
			}
			my @pac_list = ($list_text =~ m/(\S+)/gs);
			$list_text = join("\n", sort @pac_list);
		}
		$pk_lists->{$list_code} = $list_text;
	}

	$pk_lists->{'Package Files'} = $pac->{file_list}; # add file list

	return $pac->{pk_lists} = $pk_lists;
}

sub pac_fill_in_info { # not installed, in AUR
	my ($tmux, $pac) = @_;
	if (!$pac->{info} || !$pac->{info}->{'Repository'}) {
		if ($pac->{repo_nm} eq 'aur') {
			pac_add_aur_info($tmux, $pac); # pac_add_sync_info($pac, ''.`yay -Si -a '$pac->{name}'`, $pac->{info});
		} else {
			pac_add_sync_info($pac, ''.`pacman -Si '$pac->{name}'`, $pac->{info});
		}
	}
}

sub pac_add_sync_info {
	my ($pac, $info_text, $sync_props) = @_;
	$sync_props //= pac_props_parse($info_text);
	$pac->{ver_repo} = $sync_props->{'Version'};
	$pac->{dated} = defined($pac->{ver_inst}) ? ($pac->{ver_inst} eq $pac->{ver_repo} ? 'U' : 'O') : '';
	if (my $pac_info = $pac->{info}) { # installed, add sync DB info
		while (my ($prop_name, $prop_val) = each %$sync_props) {
			$pac_info->{$prop_name} //= $prop_val;
		}
	} else { # not installed
		$pac->{info} = $sync_props;
	}
	$pac->{info_text} = ($pac->{info_text} // '') . "--- Sync DB info ---\n" . $info_text;

	if (!$pac->{info}->{'Repository'}) {
		$pac->{info}->{'Repository'} = $pac->{repo_nm};
		$pac->{info_text} .= "Repository: $pac->{repo_nm}\n";
	}
}

sub pac_add_aur_info { #
	my ($tmux, $pac) = @_;
	$pac->{info}->{Votes} && return; # already filed in

	my $aur_props = ($::{aur_props} //= [
		['Repository'], ['Name'], ['Version'], ['Description'],
		['URL'], ['License', 'Licenses'], ['Keywords'], # ['Groups'],
		['Provides'], ['Depends', 'Depends On'], ['OptDepends', 'Optional Deps'],
		['MakeDepends', 'Make Deps'], ['CheckDepends', 'Check Deps'], ['Conflicts', 'Conflicts With'],
		['Replaces'], ['AUR URL'],
		['Submitter'], ['Maintainer'], ['CoMaintainers', 'Co-Maintainers'],
		['FirstSubmitted', 'First Submitted'],
		['LastModified', 'Last Modified'],
		['NumVotes', 'Votes'], ['Popularity'], ['OutOfDate', 'Out-of-date']
	]);
	my $prop_len = ($::{aur_prop_len} //= (sort {$b <=> $a} map {length($_->[1] // $_->[0])} @$aur_props)[0] + 1);

	my $pac_info_txt = `curl -sL 'https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=$pac->{name}'`;
	my $pac_obj = json_parse_obj($pac_info_txt);

	$pac_obj->{err} && do { report("Failed to get '$pac->{name}' info: $pac_obj->{msg}"); return; };
	$pac_obj = $pac_obj->{res}->{results}->[0];
	$pac_obj->{Repository} = 'aur';
	$pac_obj->{'AUR URL'} = "https://aur.archlinux.org/packages/$pac->{name}";

	my ($info, $info_text) = ({}, '');

	for my $prop_name (@$aur_props) {
		my ($pname_aur, $pname_std) = ($prop_name->[0], $prop_name->[1] // $prop_name->[0]);
		if (defined(my $prop_val = ($pac_obj->{$pname_aur}))) {
			if (ref $prop_val eq 'ARRAY') {
				$prop_val = join('  ', @$prop_val);
			} elsif ($prop_val ne '' && index('FirstSubmitted|LastModified', $pname_aur) > -1) {
				$prop_val = POSIX::strftime('%Y-%m-%d %H:%M:%S UTC', gmtime(int($prop_val)));
			}
			if ($prop_val ne '') {
				$info->{$pname_std} = $prop_val;
				$info_text .= substr($pname_std.' 'x$prop_len, 0, $prop_len)." : $prop_val\n";
			}
		}
	}

	pac_add_sync_info($pac, $info_text, $info);
}

# JSON

sub json_parse_obj {
	my ($json_text) = @_;
	my ($hier, $ppos, $obj, $pname, $pval, $objn) = ([], 0);
	my $err = sub { # compose error object from a message & JSON RegEx
		{err => $_[0], pos => $-[0], token => ($_=$1//$2//$3), msg => $_[0].': '.($-[0] // '-1').': '.$_}
	};
	$json_text =~ m/^\s*([\{\[])/s || return $err->('root must be an object'); # shortcut execution to reduce in-loop checks
	my $consts = ($::{json_parse_consts} //= {true => 1, false => '', null => undef});
	while ($json_text =~ m/\s* (?: ([\,\:\{\}\[\]]) | "( [^"\\]*+ (?:\\.[^"\\]*+)* )" | (null|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false))/gsx) {
		$ppos != $-[0] && return $err->("inconsecutive match");
		$ppos = $+[0];
		if (my $cmd_ch = $1) { # lexical characters: , : [ ] { }
			if ($cmd_ch eq ',') { # next element in map or array
				$pval || return $err->("incomplete item, missing value");
				$pname = $pval = undef;
			} elsif ($cmd_ch eq ':') { # key-value separator
				defined($pname) || return $err->("prop name not defined");
				defined($pval) && return $err->("unexpected colon");
				$pval = 0;
			} elsif ($cmd_ch eq '{' || $cmd_ch eq '[') { # start of object or array
				$objn = $cmd_ch eq '{' ? {} : [];
				if (defined($obj)) { # previous object exists (not the initial pass)
					if (ref $obj eq 'HASH') { # prev object is HASH
						defined($pname) || return $err->("unknown prop name");
						$obj->{$pname} = $objn;
					} else {
						defined($pval) && return $err->("unexpected start of obj");
						push(@$obj, $objn);
					}
					push(@$hier, $obj);
				}
				$obj = $objn;
				$pname = $pval = undef;
			} elsif ($cmd_ch eq '}') {
				ref $obj eq 'HASH' || return $err->("HASH object is expected");
				defined($pname) && !$pval && return $err->("prop $pname has no value");
				$obj = pop(@$hier) //
					return substr($json_text, $+[0]) =~ m/^\s*$/s ? {res => $obj} : $err->("text after JSON end");
				$pname = undef;
				$pval = 1;
			} elsif ($cmd_ch eq ']') {
				ref $obj eq 'ARRAY' || return $err->("wrong object type, expected ARRAY");
				$obj = pop(@$hier) //
					return substr($json_text, $+[0]) =~ m/^\s*$/s ? {res => $obj} : $err->("text after JSON end");
				$pname = undef;
				$pval = 1;
			}
		} else { # regular value
			$pval && return $err->("value was already read");

			my $val = defined($2) ?
				(index($2, "\\") == -1 ? $2 : $2 =~ s{\\(?:(["/\\bfnrt])|u([0-9a-fA-F]{4}))}{
						$1 ? $1 =~ tr|"/\\bfnrt|"/\\\b\f\n\r\t|r : chr(hex '0x'.$2)
					}gerx # JSON excaping rules: https://www.json.org/json-en.html
				) :
				(exists $consts->{$3} ? $consts->{$3} : $3);

			if (ref $obj eq 'HASH') {
				if (defined($pname)) {
					defined($pval) || return $err->("name and value must be separated");
					$obj->{$pname} = $val;
					$pval = 1;
				} else {
					$pname = $val;
				}
			} else {
				push(@$obj, $val);
				$pval = 1;
			}
		}
	}
	return $err->("JSON ended prematurely");
} # returns either {res => obj} or {err => "err", pos => 123, token => "last match", msg => "err+details"}

# POPUP logic

sub tmux_popup_display {
	my ($tmux, $item_list, $feedback_cmd, $title, $multi, $chosen) = @_;
	$title = " [ $title ]"; # █
	my $fzf_chosen = '';
	if ($chosen && @$chosen) { # mark list entries selected previously
		my $item_idx = 1;
		my $item_idx_map = {map {$_ => $item_idx++} @$item_list};
		my @chosen_idxs = map {$item_idx_map->{$_}} @$chosen;
		if (@chosen_idxs) {
			$fzf_chosen = "--bind 'load:" . join('+', map {"pos($_)+select"} @chosen_idxs) . "'";
		}
	}
	my $item_names = join("\t", @$item_list);
	report("Multiselect popup for: $item_names");
	$multi = $multi ? '-m --bind ctrl-a:select-all,space:toggle+down' : '';
	my $pop_height = '-h '.((($_ = scalar(@$item_list)) < 19 ? $_ : 19) + 3);
	my $items_in = "perl -e 'CORE::say for(q|$item_names| =~ m/([^\t]+)/g)'";
	my $items_out = "perl -0777 -ne 'CORE::say q|$feedback_cmd |.(s/\\\\v+/\t/gsr)'";

	my $binds = "--bind alt-q:abort,q:abort";
	$binds .= " --bind 'change:change-query($title)+beginning-of-line'"; #
	$binds .= " --bind 'start:beginning-of-line'";

	my $fzf_pipe = qq`$fzfx $multi --marker='#' --pointer='>' --prompt='' --no-info --disabled -q '$title' $binds $fzf_chosen`;
	system(qq`$tumx_cmd display-popup -E $pop_height "$items_in | $fzf_pipe | $items_out >> $tmux->{cmd_in}" &`);
}

sub menu_list_popper {
	my ($tmux, $menu) = @_;
	my $provider = $menu->{list} // return;

	my $list = ref($provider) eq 'CODE' ? $provider->($tmux) : $provider;
	ref($list) eq 'ARRAY' || return;
	scalar(@$list) || return;

	if (ref($list->[0]) eq 'HASH') {
		$list = [map {$_->{label}} @$list];
	}

	tmux_popup_display($tmux, $list, $menu->{code}, $menu->{label}, $menu->{multi}, $menu->{chosen} // []);
}

sub menu_handle_response {
	my ($tmux, $menu, $details) = @_;

	my $menu_handler = $menu->{handler} // return;
	ref($menu_handler) eq 'CODE' || return;

	my @sel_labels = (($details // '') =~ m{[^\t]+}gs);
	@sel_labels || return;

	$menu_handler->($tmux, $menu, \@sel_labels);
}

# LAYOUT related

sub tmux_layout {
	my ($tmux, $menu, $item_list) = @_;
	report("tmux_layout: $item_list->[0]");
	my $layout_label = $item_list->[0] || return;
	my $layout_by_label = ($::{layout_by_label} //= { map {$_->{label} => $_} @$layout_list });
	$tmux->{layout} = $layout_by_label->{$layout_label} //
		do { tmux_status_notify($tmux, "Unidentified layout: $layout_label"); return };
	$menu->{chosen} = $item_list;
	tmux_layout_render($tmux);
}

sub tmux_layout_render {
	my ($tmux) = @_;
	my $layout = $tmux->{layout}; # { code => '2', short => 'Dep/Req', list_names => ['Depends On', 'Required By'] },
	tmux_status_bar_update($tmux);
	$tmux->{comm}->(qq`resize-pane -t $tmux->{pans}->{main}->{id} -x 34\%`);
	$tmux->{comm}->(qq`resize-pane -t $tmux->{pans}->{info}->{id} -y 50\%`);

	my $list_field_names = $layout->{list_names};
	write_file("$tmux->{pans}->{botl}->{file}.title", "[ $list_field_names->[0] ]");
	$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-t'"); # refresh title

	if ($list_field_names->[1]) { # needs second bottom pane on the right
		write_file("$tmux->{pans}->{botr}->{file}.title", "[ $list_field_names->[1] ]");
		if (my $botr_id = $tmux->{pans}->{botr}->{id}) { # right bottom pane exists
			$tmux->{comm}->("send-keys -t $botr_id 'C-M-t'"); # refresh title
			$tmux->{comm}->("resize-pane -t $botr_id -x 33\%");
		} else { # create right bottom pane
			my $shell_cmd = cmd_arg(fzf_pane_cmd($tmux, 'botr'));
			$tmux->{comm}->(qq`split-window -h -l 50\% -t $tmux->{pans}->{botl}->{id} "$shell_cmd"`);
		}
	} else {
		if ($tmux->{pans}->{botr}->{id}) { # remove tmux "botr" pane
			$tmux->{comm}->("kill-pane -t $tmux->{pans}->{botr}->{id}");
			$tmux->{pans}->{botr}->{id} = undef;
		}
	}

	$tmux->{comm}->("select-pane -t $tmux->{pans}->{main}->{id}");
	($_ = $tmux->{pac}) && package_sel($tmux, $_);
}

sub pipcmd_PANFOCUSIN { # possibly unnecessary
	my ($tmux, $pane_code) = @_;
	report("pipcmd_PANFOCUSIN: $pane_code");
}

sub pipcmd_PANFOCUSOUT { # possibly unnecessary
	my ($tmux, $pane_code) = @_;
	my $pan = $tmux->{pans}->{$pane_code};
	if ($pane_code eq 'info') {
		# $tmux->{comm}->("send-keys -t $pan->{id} 'g'"); # scroll to top
	}
}

# MENU handlers, filters
sub high_level_menu_action {
	my ($tmux, $menu, $item_list) = @_;
	my $app_menu_by_label = ($::{app_menu_by_label} //= { map {$_->{label} => $_} @$app_menu_list });
	my $target_menu = $app_menu_by_label->{$item_list->[0]} //
		do { tmux_status_notify($tmux, "Can not locate menu by label: $item_list->[0]"); return };
	$target_menu->{popper}->($tmux, $target_menu);
}

sub repo_filter {
	my ($tmux, $menu, $repos) = @_;
	!@$repos && return; # exited via Esc
	$repos = [] if scalar(@{$tmux->{db}->{repo_lst}}) == scalar(@$repos);
	my $flt_repo = join("\n", @$repos); # 1 repo per line text
	$flt_repo eq ($tmux->{flt}->{repo} // '') && return; # not changed
	$tmux->{flt}->{repo} = $flt_repo;
	report("Repo filter: " . ($tmux->{flt}->{repo} =~ s/\n+/, /gr));
	$menu->{chosen} = $repos;
	pac_list_load($tmux);
	tmux_status_bar_update($tmux);
}

sub inst_filter {
	my ($tmux, $menu, $item_list) = @_;
	!@$item_list && return; # exited via Esc
	$item_list = [] if scalar(@$item_list) == scalar(@$pac_inst_states); # ALL - no filter

	my $code_by_lab = ($::{pac_inst_cd_by_lab} //= {map {$_->{label} => $_->{code}} @$pac_inst_states});
	my $codes = join('', sort grep { $_ } map {$code_by_lab->{$_}} @$item_list);
	$codes eq ($tmux->{flt}->{inst} // '') && return; # not changed
	$tmux->{flt}->{inst} = $codes;

	$menu->{chosen} = $item_list;
	pac_list_load($tmux);
	tmux_status_bar_update($tmux);
}

sub outdated_filter {
	my ($tmux, $menu, $item_list) = @_;
	!@$item_list && return; # exited via Esc

	my $code_by_lab = ($:{dated_code_by_lab} //= {map {$_->{label} => $_->{code}} @$outdated_states});
	my $code = $code_by_lab->{$item_list->[0]} // return report("Unknown state: $item_list->[0]");
	$code eq ($tmux->{flt}->{dated} // '') && return; # not changed

	$tmux->{flt}->{dated} = $code;
	report("Set 'dated' filter: $tmux->{flt}->{dated}");

	$menu->{chosen} = $item_list;
	pac_list_load($tmux);
	tmux_status_bar_update($tmux);
}

sub key_label {
	my ($cd) = @_;
	my $cd2nm = ($::{key_lab_cd2nm} //= {'C-' => 'Ctrl+', 'M-' => 'Alt+', 'S-' => 'Shift+', });
	return $cd =~ s/(?<=[CMS]\-|^)([CMS]\-)/($cd2nm->{$1})/er;
}

sub menu_keymap {
	my ($tmux) = @_;
	my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --tabs=12 --lesskey-src='$work_dir/lesskey.pop'"; # -X
	my $keymap_file = "$path_pfx.popup";
	my $key_list_text = keybindings_text();
	write_file($keymap_file, <<TEXT);
(Press 'Alt+q' to exit this popup)

$key_list_text
TEXT
	system(qq`$tumx_cmd display-popup -h 100\% -w 100\% -E "$less_cmd $keymap_file" &`);
}

sub menu_report {
	my ($tmux, $menu_item) = @_;
	my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --tabs=12 --lesskey-src='$work_dir/lesskey.pop'"; # -X
	my $keymap_file = "$path_pfx.popup";
	# walk up the tree of packages
	my $rpacs = {};
	my $cycles = {}; # {id => {cycle}}
	# report pac: $rpac = { cycles => [] }
	# cycle: $cyc = { pacs => {pacnm => $rpac}, loop => [pacnm, ...], id => '' };
	# $tmux->{db} = {repo_map => $repo_map, repo_lst => $repo_lst, pac_map => $pac_map, pac_lst => $pac_lst};
	my $pac_map = $tmux->{db}->{pac_map};
	for my $pac (@{$tmux->{db}->{pac_lst}}) {
		$pac->{inst} || next; # analyze only installed
		# duplicate for "provides" entries
		# create "requires" & "optionally requires" lists/maps
		$rpacs->{$pac->{name}} = {name => $pac->{name}};
		#my $cyc = pac_dep_cyc_exam($pac, $res_pac_reg, []) // next;
		# log this cycle
	}

	my $less_text = "$menu_item->{code}"; # TODO - implememt
	write_file($keymap_file, <<TEXT);
$less_text
TEXT
	system(qq`$tumx_cmd display-popup -h 100\% -w 100\% -E "$less_cmd $keymap_file" &`);
}

sub pac_dep_cyc_exam {
	my ($pac, $res_pac_reg, $stack, $chains) = @_;
	my $pac_name = $pac->{name} // die("Can not find a package\n");
	my $reg_pac = ($res_pac_reg->{$pac_name} //= {name => $pac_name, stage => 0}); # stage 0 - analysis started
	$reg_pac->{stage} == -1 && return; # already reviewed
	if ($reg_pac->{stage}) { # new cycle found
		# trace back the stack
		return {name => $pac_name, chain => [$pac_name]};
	}
	$reg_pac->{stage} = 1;
	my $pacs_required_txt = pac_list_get($pac)->{'Depends On'};
	my @pacs_required = ($pacs_required_txt =~ m/(?:^|\s)([^\s\=\>\<]+)/gs);
	for my $pac_req (@pacs_required) {

	}
}

sub keybindings_text {
	my ($tmux) = @_;
	my $key_list_text = join("\n", map {key_label($_->{key}) . "\t$_->{label}"} @$tmux_key_list);
	return <<"TEXT";
Main screen keebindings

$key_list_text

In list/selection popup dialogs:

Alt+q	Exit list popup
Ctrl+a	Select all (multiselect dialogs)
TEXT
}

sub menu_about {
	my ($tmux) = @_;
	my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --tabs=12 --lesskey-src='$work_dir/lesskey.pop'"; # -X
	my $about_file = "$path_pfx.popup";
	write_file($about_file, "(Press 'Alt+q' to exit this popup)\n\n".help());
	system(qq`$tumx_cmd display-popup -h 95\% -w 75 -E "$less_cmd $about_file" &`);
}

sub menu_popper_rx_filter {
	my ($tmux, $menu) = @_;
	my $prev_flt = ($_ = $tmux->{flt}->{$menu->{code}}) ? "-i ".cmd_arg($_) : '';
	my $prompt_cmd = qq`echo " $menu->{label} (Perl RegEx)"`;
	my $read_cmd = qq`read -e -r $prev_flt -p ' > ' REXFILT; echo "\$REXFILT"`;
	my $bash_read_cmd = 'REXFILT="$(bash -c '.cmd_arg($read_cmd).')"'; # ensure bash readline is used
	my $send_back_cmd = qq`echo "PACFLT $menu->{code} \$REXFILT" >> '$tmux->{cmd_in}'`;
	system("$tumx_cmd display-popup -h 4 -w 60 -E ".cmd_arg("$prompt_cmd; $bash_read_cmd; $send_back_cmd")." &");
}

sub pipcmd_PACFLT {
	my ($tmux, $details) = @_;
	report("RX flt: $details");
	my ($flt_code, $flt_regex) = ($details =~ m{^(\w+)\h+(.*)$}m);
	$flt_regex // return report("Bad filter: $details");

	my $prev_flt = $tmux->{flt}->{$flt_code} // '';
	$prev_flt eq $flt_regex && return; # not changed

	$tmux->{flt}->{$flt_code} = $flt_regex;
	pac_list_load($tmux);
	tmux_status_bar_update($tmux);
}


# STATUS bar related
sub tmux_status_bar_update {
	my ($tmux) = @_;
	my $flt = $tmux->{flt};

	my @bar_items = ();
	if ($flt->{repo}) {
		push(@bar_items, ($flt->{repo} =~ s/\n+/, /gr));
	}
	if ($flt->{inst}) {
		my $short_by_code = ($::{inst_stt_short_by_code} //= {map {$_->{code} => $_->{short}} @$pac_inst_states});
		push(@bar_items, join(', ', map {$short_by_code->{$_}} ($flt->{inst} =~ m{\S}gs)));
	}
	if ($flt->{dated}) {
		my $stt_by_code = ($::{outdated_state_by_code} //= {map {$_->{code} => $_->{short}} @$outdated_states});
		push(@bar_items, join(', ', map {$stt_by_code->{$_}} ($flt->{dated} =~ m{\S}gs)));
	}
	if ($flt->{rxf}) {
		push(@bar_items, 'By File');
	}
	if ($flt->{rxd}) {
		push(@bar_items, 'By Details');
	}

	my $bar_text = join('', map {"[$_]"} @bar_items);
	$bar_text = $bar_text ? cmd_arg($bar_text) : "''";
	$tmux->{comm}->("set window-status-current-format " . $bar_text);

	$tmux->{comm}->("set status-right " .
		cmd_arg("Menu: ${\(key_label($app_menu_map->{MAINMENU}->{key}))}  Keymap: ${\(key_label($app_menu_map->{KEYMAP}->{key}))}"));
}

sub tmux_status_notify { # shows a frief status bar notification
	my ($tmux, $msg) = @_;
	system("$tumx_cmd display-message -d 3000 ".cmd_arg($msg =~ s/\v//gsr)." &");
}

# MISC =============================

sub report {
	my ($msg, $exit_cd) = @_;
	$::{logger} //= do { # open(STDOUT, '|-', exe_path('logger'))
		open(STDOUT, '>', $log_fname) or open(STDOUT, '>>', '/dev/null') or die("No logging $!\n");
		open(STDERR, '>&=', \*STDOUT) or die("No logging $!\n");
		STDOUT->autoflush(1);
	};
	print($msg =~ s/\s*$/\n/r);
	defined($exit_cd) && exit($exit_cd);
}

sub exe_path {
	my ($exe, $exe_path) = ($_[0]);
	for my $dir (@{$::{'broken_path'} //= [($ENV{PATH} =~ m/[^\:]+/gs)]}) {
		-e ($exe_path = "$dir/$exe") && -x _ && return $exe_path;
	}
}

sub read_file {
	my ($fname, $do_not_die) = @_;
	open(my $fhandle, '<:raw', $fname) or ($do_not_die ? return : die "Couldn't open file $fname : $!");
	return do { local $/; <$fhandle> };
}

sub write_file {
	my ($file_name, $contents) = @_;
	open(my $file_handle, '>', $file_name) or die "Couldn't open file for writing ($file_name): $!";
	print $file_handle $contents;
}

sub timest {
	my ($tm) = @_;
	return strftime("%H:%M:%S", localtime($tm)) . substr(sprintf('%.3f', $tm - int($tm)), 1, 4);
}

sub run_blocking {
	my ($timeout, $sub, @args) = @_;
	my ($alrm_message) = ("b00m\n");
	my $result = eval {
		local $SIG{ALRM} = sub { die $alrm_message };
		Time::HiRes::alarm($timeout);
		my $result = $sub->(@args);
		alarm(0); # Cancel alarm
		return $result;
	};
	$@ && $@ ne $alrm_message && die($@);
	return $result;
}

sub cmd_arg { return shift =~ s/([\|\;\&\"\'\`\!\$\%\(\)\<\>\s\#\\])/\\$1/gr; }

sub help {
	my $script_name = $0 =~ m{([^/]+)$} ? $1 : die("Oddball");
	my $key_list_text = keybindings_text() =~ s/^(?=\V)/    /msgr;
	return <<"EOF";
SYNOPSIS

    $script_name [--aur]

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

    Fun fact: $script_name was tested to fit and run in 80x24 green
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

$key_list_text
EOF
}
