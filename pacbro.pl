#!/usr/bin/perl
#
# Arch package browser
#

#
# TODO: implement package management: refresh sync database, update, uninstall, etc
# TODO: auto-load AUR packages with info = "Hit <Enter> to load information"
#

use strict;
use warnings;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case);
use Time::HiRes;
use POSIX;

(`tty` =~ m{^/dev/} && $ENV{TERM}) || die("Must run in terminal\n");
my $tmux_exe = exe_path('tmux') // die("Please install tmux\n");
my $fzfx = exe_path('fzf') // die("Please install fzf\n");
my $yayx = exe_path('yay');
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

die("Install 'yay' to use AUR feature\n") if $use_aur && !$yayx;

my $shutdown_hooks = [];
my $layout_list = [
	{ code => '1', label => 'Package Files', short => 'Files' },
	{ code => '2', short => 'DepOn/ReqBy', lists => ['Depends On', 'Required By'] },
	{ code => '3', short => 'Opt Dep/For', lists => ['Optional Deps', 'Optional For'] },
	{ code => '4', short => 'Make/Check', lists => ['Make Deps', 'Check Deps'] },
	{ code => '5', short => 'Prov/Confl', lists => ['Provides', 'Conflicts With'] },
	{ code => '6', short => 'Prov/Repl', lists => ['Provides', 'Replaces'] },
];

for my $layout_item (@$layout_list) {
	$layout_item->{label} //= join(' / ', @{$layout_item->{lists}});
}

my $pac_inst_states = [
	{ code => 'N', label => 'Not Installed', short => 'Not Inst' },
	{ code => 'E', label => 'Explicitly Installed', short => 'Expl' },
	{ code => 'I', label => 'Installed as Dependency', short => 'As Dep' }
];

my $outdated_states = [
	{ code => '', label => 'Do not filter', short => '*' },
	{ code => 'O', label => 'Outdated', short => 'Old' },
	{ code => 'U', label => 'Up-to-date', short => 'New' },
];

my $cmd_map = {
	QUIT => sub { exit(0) },
	PANREADY => \&pipcmd_PANREADY,
	TMUXUP => \&pipcmd_TMUXUP,
	KEYPRESS => \&pipcmd_KEYPRESS,
	PACNAV => \&pipcmd_PACNAV,
	WINRESZ => \&tmux_layout_render,
	PANFOCUS => \&pipcmd_PANFOCUS,
	PACFLT => \&pipcmd_PACFLT,
};

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
	{ code => "REPOFILTER", label => 'Select Repos', key => 'M-r', popper => \&menu_list_popper, handler => \&repo_filter, multi => 1 },
	{ code => "INSTFILTER", label => 'Installed Status Filter', key => 'M-i', popper => \&menu_list_popper, handler => \&inst_filter, multi => 1, list => $pac_inst_states },
	{ code => "OUTDATED", label => 'Outdated Status Filter', key => 'M-o', popper => \&menu_list_popper, handler => \&outdated_filter, multi => 0, list => $outdated_states },
	{ code => "rxf", label => 'Search filenames', key => 'M-f', popper => \&menu_popper_rx, flt => 'frx' },
	{ code => "rxd", label => 'Search package details', key => 'M-d', popper => \&menu_popper_rx, flt => 'drx' },
	{ code => "MAINMENU", label => 'Main Menu', key => 'M-m', popper => \&menu_list_popper, handler => \&high_level_menu_action, multi => 0 },
	{ code => "KEYMAP", label => 'Keyboard Shortcuts', key => 'M-k', popper => \&menu_keymap },
	{ code => "ABOUT", label => 'Help / About', key => 'M-?', popper => \&menu_about },
];

my $app_menu_map = {};
for my $menu (@$app_menu_list) {
	$app_menu_map->{$menu->{code}} = $menu;
	push(@$tmux_key_list, { key => $menu->{key}, foo => sub { $menu->{popper}->($_[0], $menu) }, label => $menu->{label}, menu => $menu });
	$cmd_map->{$menu->{code}} = sub { menu_handle_response($_[0], $menu, $_[1]) };
}
$app_menu_map->{MAINMENU}->{list} = $app_menu_list;

# create files for each pane
my $tmux_pan_list = [
	{ code => 'main', key => 'C-Left', label => 'Main package list' },
	{ code => 'info', key => 'C-Up', label => 'Package info' },
	{ code => 'botl', key => 'C-Down', label => 'Detail list 1' },
	{ code => 'botr', key => 'C-Right', label => 'Detail list 2' },
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

while (my $msg = tmux_next_msg($tmux)) {
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

	my $tpid = fork();
	if ($tpid == 0) {
		my $less_cmd = "less -X -~ -S -Q -P '~' --mouse"; # -X
		my $info_cmd = "echo PANREADY info \\\$TMUX_PANE >> $cmd_in; while : ; do $less_cmd $tmux->{pans}->{info}->{file}; done";

		my $main_file = $tmux->{pans}->{main}->{file};
		my $sel_action = "execute-silent(echo PACNAV {} >> $tmux->{cmd_in})";
		my $binds = "--bind enter:'$sel_action' --bind double-click:'$sel_action'";
		$binds .= " --bind focus:'$sel_action'" if !$use_aur; # do not auto-load package info
		$binds .= " --bind 'ctrl-alt-r:reload(cat $main_file)'";
		$binds .= " --bind 'load:first'";
		$binds .= " --bind 'start:unbind(ctrl-c,ctrl-g,ctrl-q,esc)'"; # do not allow exiting keys
		my $pane_fzf = "cat $main_file 2>/dev/null | $fzfx --cycle $binds";
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
			"[ -p '$cmd_in' ] && perl -e 'alarm 2; sysopen(FH, q|$cmd_in|, Fcntl::O_WRONLY|Fcntl::O_APPEND) and CORE::say FH q|QUIT|' ;" .
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
	my ($tmux, $pane_code) = @_;
	my $file = $tmux->{pans}->{$pane_code}->{file};
	my $tit_file = "$file.title";
	my $sel_action = "execute-silent(echo PACNAV {} >> $tmux->{cmd_in})";
	my $binds = "--bind enter:'$sel_action' --bind double-click:'$sel_action'";
	$binds .= " --bind 'ctrl-alt-r:reload(cat ${\(cmd_arg($file))})'";
	$binds .= " --bind 'ctrl-alt-t:transform-query(cat ${\(cmd_arg($tit_file))})'";
	$binds .= " --bind 'start:unbind(ctrl-c,ctrl-g,ctrl-q,esc)'"; # do not allow exiting keys
	$binds .= " --bind 'start:reload(cat ${\(cmd_arg($file))})'";
	$binds .= " --bind 'start:transform-query(cat ${\(cmd_arg($tit_file))})'";
	$binds .= " --bind 'load:first'";
	my $pane_fzf = "cat '$file' 2>/dev/null | $fzfx --disabled --no-info $binds";
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

	$tmux->{comm}->(qq`set-hook -w window-resized "run 'echo WINRESZ >> $tmux->{cmd_in}'"`);
	for my $pan (@$tmux_pan_list) {
		#$tmux->{comm}->(qq`set-hook -p -t $pan->{id} pane-focus-in "run 'echo PANFOCUS $pan->{code} >> $tmux->{cmd_in}'"`);
		#report(qq`set-hook -p -t $pan->{id} pane-focus-in "run 'echo PANFOCUS $pan->{code} >> $tmux->{cmd_in}'"`);
	}

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

sub tmux_next_msg {
	my ($tmux) = @_;
	my $from_tmux = $tmux->{from_tmux};
	if (defined($from_tmux) && scalar(@$from_tmux)) {
		return pop(@$from_tmux);
	}
	while ($tmux->{cmd_in}) {
		if (my $msgs_text = run_blocking(1, sub { read_file($tmux->{cmd_in}, 1) })) {
			my @lines = ($msgs_text =~ m/\V+/gs);
			$tmux->{from_tmux} = scalar(@lines) ? \@lines : next;
			return tmux_next_msg($tmux);
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
		return file_sel($tmux, $tmux->{pac_file} = $pac_nm);

	$pac_nm = $pac_nm =~ m/^(\S+)/ ? $1 : return tmux_status_notify($tmux, "Bad package spec: $pac_nm");

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

	pac_fill_in_info($pac);

	if (!($_ = $tmux->{pac}) || $_->{name} ne $pac->{name}) { # if package is different
		write_file("$tmux->{pans}->{info}->{file}", $pac->{info_text} // '');
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{info}->{id} R");
	}
	$tmux->{pac} = $pac;

	my $layout = $tmux->{layout}; # depending on the layout
	if ($layout->{code} eq '1') {
		write_file("$tmux->{pans}->{botl}->{file}", $pac->{file_list} // '');
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-r'");
	} else {
		my $pac_deps = pac_list_get($pac); # $pac->{lists} // {};
		my $list_field_names = $layout->{lists};

		write_file("$tmux->{pans}->{botl}->{file}", $pac_deps->{$list_field_names->[0]} // '');
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-r'");

		write_file("$tmux->{pans}->{botr}->{file}", $pac_deps->{$list_field_names->[1]} // '');
		$tmux->{pans}->{botr}->{id} &&
			$tmux->{comm}->("send-keys -t $tmux->{pans}->{botr}->{id} 'C-M-r'");
	}
}

sub file_sel {
	my ($tmux, $file) = @_;
	-f $file || return;
	my $pani = $tmux->{pans}->{info};
	system("(grep -IF '' '$file' || file -b '$file') > '$pani->{file}'");
	$tmux->{comm}->("send-keys -t $pani->{id} R");
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
	# name, inst [EIN], repo_nm, repo, ver_inst, ver_repo, dated, info{}, lists{}, info_text, file_list

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
	($_ = $pac->{lists}) && return $_;

	my $list_prop_list = ($::{pac_list_prop_list} //=
		['Depends On', 'Required By', 'Optional Deps', 'Optional For', 'Make Deps', 'Check Deps', 'Provides', 'Conflicts With', 'Replaces']);

	my $pac_info = $pac->{info};
	my $pac_lists = {};

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
		$pac_lists->{$list_code} = $list_text;
	}
	return $pac->{lists} = $pac_lists;
}

sub pac_fill_in_info { # not installed, in AUR
	my ($pac) = @_;
	if (!$pac->{info}) {
		my $pac_list_exe = $pac->{repo_nm} eq 'aur' ? "yay -Si -a" : "pacman -Si";
		#die(`$pac_list_exe $pac->{name}`);
		my $info_text = `$pac_list_exe $pac->{name}`;
		pac_add_sync_info($pac, $info_text, undef);
	}
}

sub pac_add_sync_info {
	my ($pac, $info_text, $sync_props) = @_;
	$sync_props //= pac_props_parse($info_text);
	$pac->{ver_repo} = $sync_props->{'Version'};
	$pac->{dated} = defined($pac->{ver_inst}) ? ($pac->{ver_inst} eq $pac->{ver_repo} ? 'U' : 'O') : '';
	if (my $pac_info = $pac->{info}) { # installed, add sync DB info
		while (my ($prop_name, $prop_val) = each %$sync_props) { # add "lists" from sync db
			$pac_info->{$prop_name} //= $prop_val;
		}
	} else { # not installed
		$pac->{info} = $sync_props;
	}
	$pac->{repo_nm} //= $sync_props->{'Repository'};
	$pac->{info_text} = ($pac->{info_text} // '') . "--- Sync DB info ---\n" . $info_text;
}

sub pac_info_aur { #
	my ($tmux, $pac_nm) = @_;
	my $pac_info_txt = `curl -sL 'https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=$pac_nm'`;
	my $pac_json = json_parse($pac_info_txt, 0);
}

sub json_parse {
	my ($json_text, $idx) = @_;
	my ($hier, $obj, $pname, $pval) = ([]);
	my $consts = ($::{json_consts} //= {true => 1, false => '', null => undef});
	while ($json_text =~ m/\s* (?: ([\{\}\[\]\:\,]) | " ((?:[^"\\]+|\\.)*) " | (true|false|null|\d+) ) \s*/gsx) {
		if (my $cmd_ch = $1) { # new struc
			if ($cmd_ch eq ',') { # next element in map or array
				defined($obj) || return {err => "bad JSON at $-[0]: $cmd_ch"};
				$pval || return {err => "bad JSON at $-[0]: $cmd_ch, incomplete item"};
				$pval = undef;
				$pname = undef;
				# implement or ignore
			} elsif ($cmd_ch eq ':') {
				defined($obj) || return {err => "bad JSON at $-[0]: $cmd_ch, object not defined"};
				ref $obj eq 'HASH' || return {err => "bad JSON at $-[0]: $cmd_ch, object not hash"};
				defined($pname) || return {err => "bad JSON at $-[0]: $cmd_ch, prop name not defined"};
				$pval && return {err => "bad JSON at $-[0]: $cmd_ch, prop $pname value already defined"};
			} elsif ($cmd_ch eq '{' || $cmd_ch eq '[') {
				(defined($pname) || defined($pval)) && return {err => "bad JSON at $-[0]: $cmd_ch, prop $pname has no value"};
				my $new_obj = $cmd_ch eq '{' ? {} : [];
				if (defined($obj)) { # last object exists
					if (ref $obj eq 'HASH') { # prev object is HASH
						defined($pname) || return {err => "bad JSON at $-[0]: $cmd_ch, unknown prop name"};
						$obj->{$pname} = $new_obj;
						$pname = undef;
					} else {
						push(@$obj, $new_obj);
					}
					push(@$hier, $obj);
				}
				$obj = $new_obj;
			} elsif ($cmd_ch eq '}') {
				defined($obj) || return {err => "bad JSON at $-[0]: $cmd_ch, object not defined"};
				ref $obj eq 'HASH' || return {err => "bad JSON at $-[0]: $cmd_ch, object not hash"};
				defined($pname) && !$pval && return {err => "bad JSON at $-[0]: $cmd_ch, prop $pname has no value"};
				$obj = pop(@$hier);
				$pval = undef;
				$pname = undef;
			} elsif ($cmd_ch eq ']') {
				defined($obj) || return {err => "bad JSON at $-[0]: $cmd_ch, object not defined"};
				ref $obj eq 'ARRAY' || return {err => "bad JSON at $-[0]: $cmd_ch, object not hash"};
				defined($pname) && return {err => "bad JSON at $-[0]: $cmd_ch, prop $pname in array"};
				$obj = pop(@$hier);
				$pval = undef;
			}
		} else {
			# defined($lvalue) && return {err => "bad JSON at $-[0]: $cmd_ch, prev value was unclaimed"};
			defined($obj) || return {err => "bad JSON at $-[0]: $cmd_ch, object not defined"};
			my $val = $3 && exists $consts->{$3} ? $consts->{$3} : $2 // $3;
			if (ref $obj eq 'HASH') {
				defined($pval) && return {err => "bad JSON at $-[0]: $cmd_ch, value already defined"};
				if ($pval = defined($pname)) {
					$obj->{$pname} = $val;
				} else {
					$pname = $val;
				}
			} elsif (ref $obj eq 'ARRAY') {
				$pval = 1;
				push(@$obj, $val);
			}
		}
	}
	scalar(@$hier) && return {err => "bad JSON, object not complete"};
	return $obj;
}

# POPUP logic

sub tmux_popup_display {
	my ($tmux, $item_list, $feedback_cmd, $title, $multi, $chosen) = @_;
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
	$multi = $multi ? '-m --bind ctrl-a:select-all' : '';
	my $pop_height = '-h '.((($_ = scalar(@$item_list)) < 19 ? $_ : 19) + 3);
	my $items_in = "perl -e 'CORE::say for(q|$item_names| =~ m/([^\t]+)/g)'";
	my $items_out = "perl -0777 -ne 'CORE::say q|$feedback_cmd |.(s/\\\\v+/\t/gsr)'";
	my $fzf_pipe = qq`$fzfx $multi --marker='# ' --pointer='█' --no-info --disabled -q '$title' --bind alt-q:abort $fzf_chosen`;
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
	my $layout = $tmux->{layout}; # { code => '2', short => 'Dep/Req', lists => ['Depends On', 'Required By'] },
	tmux_status_bar_update($tmux);
	$tmux->{comm}->(qq`resize-pane -t $tmux->{pans}->{main}->{id} -x 34\%`);
	$tmux->{comm}->(qq`resize-pane -t $tmux->{pans}->{info}->{id} -y 50\%`);
	if ($layout->{code} eq '1') {
		write_file("$tmux->{pans}->{botl}->{file}.title", "[ Package Files ]");
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-t'");

		write_file("$tmux->{pans}->{botr}->{file}", "");
		write_file("$tmux->{pans}->{botr}->{file}.title", "");
		if ($tmux->{pans}->{botr}->{id}) {
			$tmux->{comm}->("kill-pane -t $tmux->{pans}->{botr}->{id}");
			$tmux->{pans}->{botr}->{id} = undef;
		}
	} else {
		my $list_field_names = $layout->{lists};
		write_file("$tmux->{pans}->{botl}->{file}.title", "[ $list_field_names->[0] ]");
		$tmux->{comm}->("send-keys -t $tmux->{pans}->{botl}->{id} 'C-M-t'");

		write_file("$tmux->{pans}->{botr}->{file}.title", "[ $list_field_names->[1] ]");
		if (my $botr_id = $tmux->{pans}->{botr}->{id}) {
			$tmux->{comm}->("send-keys -t $botr_id 'C-M-t'");
			$tmux->{comm}->("resize-pane -t $botr_id -x 33\%");
		} else {
			my $shell_cmd = cmd_arg(fzf_pane_cmd($tmux, 'botr'));
			$tmux->{comm}->(qq`split-window -h -l 50\% -t $tmux->{pans}->{botl}->{id} "$shell_cmd"`);
		}
	}
	$tmux->{comm}->("select-pane -t $tmux->{pans}->{main}->{id}");
	($_ = $tmux->{pac}) && package_sel($tmux, $_);
}

sub pipcmd_PANFOCUS { # possibly unnecessary
	my ($tmux, $pane_code) = @_;
	report("pipcmd_PANFOCUS: $pane_code");
	if ($tmux->{layout}->{code} eq '1' && $pane_code eq 'botr') {
		$tmux->{comm}->("select-pane -t $tmux->{pans}->{botl}->{id}");
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
	my $flt_repo = join("\n", @$repos);
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
	my $codes = join('', grep { $_ } map {$code_by_lab->{$_}} @$item_list);
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
	my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --tabs=12"; # -X
	my $keymap_file = "$path_pfx.popup";
	my $key_list_text = keybindings_text();
	write_file($keymap_file, <<TEXT);
(Press 'q' to exit this popup)

$key_list_text
TEXT
	system(qq`$tumx_cmd display-popup -h 100\% -w 100\% -E "$less_cmd $keymap_file" &`);
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
	my $less_cmd = "less -X -~ -S -Q -P '~' --mouse --tabs=12"; # -X
	my $about_file = "$path_pfx.popup";
	write_file($about_file, "(Press 'q' to exit this popup)\n\n".help());
	system(qq`$tumx_cmd display-popup -h 95\% -w 75 -E "$less_cmd $about_file" &`);
}

sub menu_popper_rx {
	my ($tmux, $menu) = @_;
	my $prev_flt = ($_ = $tmux->{flt}->{$menu->{code}}) ? "-i ".cmd_arg($_) : '';
	my $prompt_cmd = qq`echo " $menu->{label} (Perl RegEx)"`;
	my $read_cmd = "read -e -r $prev_flt -p ' > ' REXFILT; echo \$REXFILT";
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
	$bar_text = $bar_text ? cmd_arg("Filt: " . $bar_text) : "''";
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
        slower. NOTE. "yay" needs to be installed in order to use
        this feature.

    --help | -h
        help! I need somebody!

ABOUT

    The main list on the left displays the loaded list of packages.
    If can be filtered by either package name typed into the
    search box on the top of the list, of with one of canned
    filters described below. The list is assembled with the help
    of "pacman" and "yay" if executed with the "--aur" option.

    The top panel displays one of the following:
    * package information fetched with pacman -Qi|-Si
    * selected package file contents or type

    The bottom panels display:
    * related package lists
    * list of files installed from the package
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
    * yay: needed when AUR feature is enabled via '--aur'

AUR

    For AUR packages to be loaded, "yay" must be installed and
    "--aur" argument passed to this program.

    It is impractical to load details of all packages in AUR,
    there are just too many of them. This means search by package
    details doesn't work for not installed AUR packages.

    For the same reason auto display of package details is disabled,
    when AUR listing is on. You need to explicitly hit <Enter> on
    the package in order to fetch package details from the web.

KEYBINDINGS

$key_list_text
EOF
}
