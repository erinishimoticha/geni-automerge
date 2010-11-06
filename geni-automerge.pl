#!/usr/bin/perl

use strict;
use WWW::Mechanize;
use HTTP::Cookies;
use Class::Struct;
use IO::File;
use Time::HiRes;
use JSON;

# globals and constants
my (%env, %debug, $debug_fh, $merge_log_fh, $m, %blacklist_managers);
my $m = WWW::Mechanize->new(autocheck => 0);
my $DBG_NONE			= "DBG_NONE"; # Normal output
my $DBG_PROGRESS		= "DBG_PROGRESS";
my $DBG_URLS			= "DBG_URLS";
my $DBG_IO			= "DBG_IO";
my $DBG_MATCH_DATE		= "DBG_MATCH_DATE";
my $DBG_MATCH_BASIC		= "DBG_MATCH_BASIC";

init();
main();

sub init(){
	# configuration
	$env{'circa_range'}		= 1;
	$env{'get_timeframe'}		= 10;
	$env{'get_limit'}		= 18; # Amos has the limit set to 20 so we'll use 18 to have some breathing room
	$env{'datadir'} 		= "script_data";
	$env{'logdir'}			= "logs";

	# environment
	$env{'start_time'}		= time();

	# todo: Once we are all running this script from the same machine
	# merge_log_file needs to be the same file for all users.
	$env{'merge_log_file'}		= "$env{'logdir'}/merge_log.html";
	$env{'history_file'}		= "$env{'datadir'}/get_history.txt";
	$env{'log_file'}		= "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . ".html";
	$env{'matches'} 		= 0;
	$env{'profiles'}		= 0;

	# logging
	(mkdir $env{'datadir'}, 0755) if !(-e $env{'datadir'});
	(mkdir $env{'logdir'}, 0755) if !(-e $env{'logdir'});

	$merge_log_fh				= createWriteFH("Merge History", $env{'merge_log_file'}, 1);
	$merge_log_fh->autoflush(1);
	$debug_fh				= createWriteFH("logfile", $env{'log_file'}, 0);
	$debug_fh->autoflush(1);
	$debug{"file_" . $DBG_NONE}		= 1;
	$debug{"file_" . $DBG_PROGRESS}		= 1;
	$debug{"file_" . $DBG_IO}		= 0;
	$debug{"file_" . $DBG_URLS}		= 1;
	$debug{"file_" . $DBG_MATCH_BASIC}	= 1;
	$debug{"file_" . $DBG_MATCH_DATE}	= 1;
	$debug{"console_" . $DBG_NONE}		= 0;
	$debug{"console_" . $DBG_PROGRESS}	= 1;
	$debug{"console_" . $DBG_IO}		= 0;
	$debug{"console_" . $DBG_URLS}		= 0;
	$debug{"console_" . $DBG_MATCH_BASIC}	= 0;
	$debug{"console_" . $DBG_MATCH_DATE}	= 0;

	struct (profile => {
		name_first		=> '$',
		name_middle		=> '$',
		name_last		=> '$',
		name_maiden		=> '$',
		suffix			=> '$',
		gender			=> '$',
		living			=> '$',
		birth_year		=> '$',
		birth_date		=> '$',
		birth_location		=> '$',
		death_year		=> '$',
		death_date		=> '$',
		death_location		=> '$',
		id			=> '$',
		fathers			=> '$',
		mothers			=> '$',
		spouses			=> '$'
	});

	# It is a long story but for now don't merge profiles managed by the following:
	# http://www.geni.com/people/Wendy-Hynes/6000000003753338015#/tab/overview
	# http://www.geni.com/people/Alan-Sciascia/6000000009948172621#/tab/overview
        $blacklist_managers{"6000000003753338015"} = 1;
        $blacklist_managers{"6000000009948172621"} = 1;
}


#
# Print the syntax for running the script including all command line options
#
sub printHelp() {
	print STDERR "\nmerge_dr.pl\n\n";
	print STDERR "-u \"user\@email.com\"\n";
	print STDERR "-p password\n";
	print STDERR "-circa X (optional): X defines the number of +/- years for date matching.  5 is the default\n";
	print STDERR "-rb X (optional): rb is short for -range_begin, X is the starting page\n";
	print STDERR "-re X (optional): re is short for -range_end, X is the ending page\n";
	print STDERR "-pm X Y: pm is short for -pendingmerge.  X and Y are the two profile IDs to merge\n";
	print STDERR "-h -help : print this menu\n\n";
	print STDERR "\n";
	exit(0);
}

#
# Print debug output to STDERR and to the logfile
#
sub printDebug($$) {
	my $debug_flag = shift;
	my $msg = shift;
	if ($debug{"console_" . $debug_flag}) {
		print STDERR $msg;
	}
	if ($debug{"file_" . $debug_flag} && $debug_fh) {
		print $debug_fh $msg;
	}
}

#
# Print the die_message and logout of geni
#
sub gracefulExit($) {
	my $msg = shift;
	printDebug($DBG_NONE, "$env{'matches'} matches out of $env{'profiles'} profiles\n");
	printDebug($DBG_NONE, $msg);
	geniLogout();
	exit();
}

#
# Create a FH for reading a file and return that FH
#
sub createReadFH($) {
	my $filename = shift;
	my $fh = new IO::File;
	$fh->open("$filename", "r") || gracefulExit("\n\nERROR: createReadFH could not open '$filename'\n\n");
	return $fh;
}

#
# Create a FH for writing to a file and return that FH
#
sub createWriteFH($$$) {
	my $debug_msg = shift;
	my $filename = shift;
	my $append = shift;

	my $fh = new IO::File;
	if ($append) {
		$fh->open(">> $filename") || gracefulExit("\n\nERROR: createWriteFH could not open append '$filename'\n\n");
		printDebug($DBG_NONE, "$debug_msg: Appending to '$filename'\n") if $debug_msg;
	} else {
		$fh->open("> $filename") || gracefulExit("\n\nERROR: createWriteFH could not open '$filename'\n\n");
		printDebug($DBG_NONE, "$debug_msg: Creating '$filename'\n") if $debug_msg;
	}
	return $fh;
}

sub prependZero($) {
	my $num = shift;
	return $num =~ /^\d$/ ? "0" . $num : $num;
}

sub dateHourMinuteSecond() {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$year += 1900;
	$mon += 1;
	$mon  = prependZero($mon);
	$mday = prependZero($mday);
	$hour = prependZero($hour);
	$min  = prependZero($min);
	$sec  = prependZero($sec);

	return "$year\_$mon\_$mday\_$hour\_$min\_$sec";
}

sub todaysDate() {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$year += 1900;
	$mon += 1;
	$mon  = prependZero($mon);
	$mday = prependZero($mday);

	return "$year\_$mon\_$mday";
}

# This isn't working yet
sub geniLoginAPI() {
	$m->cookie_jar(HTTP::Cookies->new());
	$m->post("https://www.geni.com/login/in&username=$env{'username'}&password=$env{'password'}");
}

#
# Do a secure login into geni
#
sub geniLogin() {
	$m->cookie_jar(HTTP::Cookies->new());
	$m->get("https://www.geni.com/login");
	$m->form_number(2);
	$m->field("profile[username]" => $env{'username'});
	$m->field("profile[password]" => $env{'password'});
	$m->click();
	
	my $login_fh = createWriteFH("", "$env{'datadir'}/login.html", 0);
	my $output = $m->content();
	print $login_fh $output;
	undef $login_fh;

	if ($output =~ /Welcome to Geni/i) {
		printDebug($DBG_NONE, "ERROR: Login FAILED for www.geni.com!!\n");
		exit();
	}

	printDebug($DBG_NONE, "Login PASSED for www.geni.com!!\n");
}

#
# Logout of geni
#
sub geniLogout() {
	printDebug($DBG_NONE, "Logging out of www.geni.com\n");
	$m->get("http://www.geni.com/logout?ref=ph");
}

sub jsonSanityCheck($) {
	my $filename = shift;

	my $fh = createReadFH($filename);
	my $json_data = <$fh>;
	undef $fh;

	# We "should" never hit this
	if ($json_data =~ /Rate limit exceeded/i) {
		gracefulExit("ERROR: 'Rate limit exceeded' for '$filename'\n");
		return 0;
	}

	# Some profiles are private and we cannot access them
	if ($json_data =~ /Access denied/i) {
		return 0;
	}

	# I've only seen this once.  Not sure what the trigger is or if the
	# sleep will fix it.
	if ($json_data =~ /500 read timeout/i) {
		sleep(10);
		return 0;
	}

	if ($json_data =~ /DOCTYPE HTML PUBLIC/) {
		printDebug($DBG_NONE, "ERROR: 'DOCTYPE HTML PUBLIC' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/tatus read failed/) {
		printDebug($DBG_NONE, "ERROR: 'Status read failed' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/an't connect to www/) {
		printDebug($DBG_NONE, "ERROR: 'Can't connect to www' for '$filename'\n");
		return 0;
	}

	return 1;
}

#
# Return TRUE if $time_A and $time_B are within $threshold of each other.
# $threshold should be in seconds.
#
# Always pass the most recent time as time_A. The time strings look like:
# EpochSeconds.Microseconds
# 1288721911.894155
# 1288721917.83155
# 1288721923.200155
# 1288721928.390155
#
sub timesInRange($$$) {
	my $time_A = shift;
	my $time_B = shift;
	my $threshold = shift;

	gracefulExit("ERROR: Don't call timesInRange with a threshold of 0\n") if !$threshold;

	(my $time_A_sec, my $time_A_usec) = split(/\./, $time_A);
	(my $time_B_sec, my $time_B_usec) = split(/\./, $time_B);

	my $delta = 0;

	if ($time_A_sec == $time_B_sec) {
		$delta += $time_A_usec - $time_B_usec;
	} else {
		my $whole_seconds_delta = ($time_A_sec - $time_B_sec) - 1;
		if ($whole_seconds_delta >= 1) {
			$delta += ($whole_seconds_delta * 1000000);
		}

		$delta += $time_A_usec;
		$delta += (1000000 - $time_B_usec);
	}

	if ($delta <= ($threshold * 1000000)) {
		# printf("timesInRange: time_A ($time_A), time_B ($time_B), delta($delta), return 1\n");
		return 1;
	}

	# printf("timesInRange: time_A ($time_A), time_B ($time_B), delta($delta), return 0\n");
	return 0;
}

sub getPage($$) {
	my $filename = shift;
	my $url = shift;

	if (-e "$filename") {
		printDebug($DBG_IO, "getPage(cached): $url\n");
		return;
	}

	printDebug($DBG_IO, "getPage(fetch): $url\n");

	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	my $time_current = "$time_sec.$time_usec";

	# todo(maybe): If I someday start running multiple copies of the
	# script at once (per user) then use a lock file so multiple threads
	# don't access get_history at once
	my $gets_in_last_ten_seconds = 0;
	my @get_history;
	if (-e $env{'history_file'}) {
		my $get_history_fh = createReadFH($env{'history_file'});
		while(<$get_history_fh>) {
			chomp();
			push @get_history, $_;
			# print "GET_HISTORY_READ: $_\n";

			if (timesInRange($time_current, $_, $env{'get_timeframe'})) {
				$gets_in_last_ten_seconds++;
			}
		}
		undef $get_history_fh;
	}

	if ($gets_in_last_ten_seconds >= $env{'get_limit'}) {
		printDebug($DBG_NONE, "$gets_in_last_ten_seconds gets() in the past $env{'get_timeframe'} seconds....sleeping....\n");
		sleep(1);
	}

	my $fh = createWriteFH("", $filename, 0);
	$m->get($url);
	print $fh $m->content();
	undef $fh;

	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	$time_current = "$time_sec.$time_usec";

	push @get_history, $time_current;
	my $get_history_fh = createWriteFH("", $env{'history_file'}, 0);
	foreach my $i (@get_history) {
		if (timesInRange($time_current, $i, $env{'get_timeframe'} * 2)) {
			print $get_history_fh "$i\n";
			# print "GET_HISTORY_WRITE: $i\n";
		}
	}
	undef $get_history_fh;
}

#
# Return TRUE if year1 or year2 were marked with circa and fall within +/- 5 years of each other.
# Else only return TRUE if they match exactly
#
sub yearInRange($$$) {
	my $year1 = shift;
	my $year2 = shift;
	my $circa = shift;

	return (abs(($year1) - ($year2)) <= $env{'circa_range'} ? $env{'circa_range'} : 0) if $circa;
	return ($year1 == $year2); 
}

sub monthDayYear($) {
	my $date = shift;

	my $date_month = 0;
	my $date_day = 0;
	my $date_year = 0;

	# 7/1/1700
	if ($date =~ /(\d+)\/(\d+)\/(\d+)/) {
		$date_month	= $1;
		$date_day	= $2;
		$date_year	= $3;

	# July 1700
	} elsif ($date =~ /(\w+) (\d+)/) {
		$date_month = $1;
		$date_year  = $2;
			  if ($date_month =~ /jan/i) { $date_month = 1;
		} elsif ($date_month =~ /feb/i) { $date_month = 2;
		} elsif ($date_month =~ /mar/i) { $date_month = 3;
		} elsif ($date_month =~ /apr/i) { $date_month = 4;
		} elsif ($date_month =~ /may/i) { $date_month = 5;
		} elsif ($date_month =~ /jun/i) { $date_month = 6;
		} elsif ($date_month =~ /jul/i) { $date_month = 7;
		} elsif ($date_month =~ /aug/i) { $date_month = 8;
		} elsif ($date_month =~ /sep/i) { $date_month = 9;
		} elsif ($date_month =~ /oct/i) { $date_month = 10;
		} elsif ($date_month =~ /nov/i) { $date_month = 11;
		} elsif ($date_month =~ /dec/i) { $date_month = 12;
		}

	# 1700
	} elsif ($date =~ /(\d+)/) {
		$date_year  = $1;

	# July
	} elsif ($date =~ /(\w+)/) {
		$date_month = $1;
			  if ($date_month =~ /jan/i) { $date_month = 1;
		} elsif ($date_month =~ /feb/i) { $date_month = 2;
		} elsif ($date_month =~ /mar/i) { $date_month = 3;
		} elsif ($date_month =~ /apr/i) { $date_month = 4;
		} elsif ($date_month =~ /may/i) { $date_month = 5;
		} elsif ($date_month =~ /jun/i) { $date_month = 6;
		} elsif ($date_month =~ /jul/i) { $date_month = 7;
		} elsif ($date_month =~ /aug/i) { $date_month = 8;
		} elsif ($date_month =~ /sep/i) { $date_month = 9;
		} elsif ($date_month =~ /oct/i) { $date_month = 10;
		} elsif ($date_month =~ /nov/i) { $date_month = 11;
		} elsif ($date_month =~ /dec/i) { $date_month = 12;
		}

	}

	return ($date_month, $date_day, $date_year);
}

#
# Return true if the dates match or if one is a more specific date within the same year
#
sub dateMatches($$) {
	my $date1 = shift;
	my $date2 = shift;

	if ($date1 eq $date2) {
		# To reduce debug output, don't print the debug when both are "" 
		if ($date1 ne "") {
			printDebug($DBG_MATCH_DATE, "DATES: date1 ($date1), date2($date2) MATCHED\n");
		}
		return 1;
	}

	printDebug($DBG_MATCH_DATE, "DATES: date1 ($date1), date2($date2)");

	# If one date is blank and the other is not then we consider one to be more specific than the other
	if (($date1 ne "" && $date2 eq "") ||
		 ($date1 eq "" && $date2 ne "")) {
		printDebug($DBG_MATCH_DATE, "  MATCHED\n");
		return 1;
	} 

	my $date1_month = 0;
	my $date1_day	= 0;
	my $date1_year  = 0;
	my $date2_month = 0;
	my $date2_day	= 0;
	my $date2_year  = 0;
	my $circa	= 0;

	# Remove the circa "c."
	if ($date1 =~ /c\.\s+(.*?)$/) {
		$circa = 1;
		$date1 = $1;
	}

	# Remove the circa "c."
	if ($date2 =~ /c\.\s+(.*?)$/) {
		$circa = 1;
		$date2 = $1;
	}

	($date1_month, $date1_day, $date1_year) = monthDayYear($date1);
	($date2_month, $date2_day, $date2_year) = monthDayYear($date2);

	# If the year is pre 1750 then assume circa.  If you don't do this there are too many dates that
	# are off by a year or two that never match
	if ($circa == 0 &&
		(($date1_year != 0 && $date1_year <= 1750) ||
		($date2_year != 0 && $date2_year <= 1750))) {
		$circa = 1;
	}

	printDebug($DBG_MATCH_DATE, "\n date1_month: $date1_month\n");
	printDebug($DBG_MATCH_DATE, " date1_day  : $date1_day\n");
	printDebug($DBG_MATCH_DATE, " date1_year : $date1_year\n");
	printDebug($DBG_MATCH_DATE, " date2_month: $date2_month\n");
	printDebug($DBG_MATCH_DATE, " date2_day  : $date2_day\n");
	printDebug($DBG_MATCH_DATE, " date2_year : $date2_year\n");
	printDebug($DBG_MATCH_DATE, " circa      : $circa\n\n");

	if (yearInRange($date1_year, $date2_year, $circa)) {
		if ($date1_month == $date2_month) {
			if ($date1_day == $date2_day) {
				printDebug($DBG_MATCH_DATE, "  MATCHED\n");
				return 1;
			} elsif ($date1_day == 0 || $date2_day == 0) {
				printDebug($DBG_MATCH_DATE, "  MATCHED\n");
				return 1;
			}
		} elsif ($date1_month == 0 || $date2_month == 0) {
				printDebug($DBG_MATCH_DATE, "  MATCHED\n");
			return 1;
		}
	}

	printDebug($DBG_MATCH_DATE, "  DID NOT MATCH\n");
	return 0;
}

#
# Construct names consistently 
#
sub cleanupNames($$$$$) {
	my $gender	= shift;
	my $first	= shift;
	my $middle	= shift;
	my $last	= shift;
	my $maiden	= shift;

	# printDebug($DBG_NONE, "cleanupNames with first($first) middle($middle) last($last) maiden($maiden)\n";
	my $name_whole = lc($first);

	if ($gender eq "female" && $maiden ne "") {
		$last = $maiden;
	}

	if ($middle) {
		if ($name_whole) {
			$name_whole .= " ";
		}
		$name_whole .=	lc($middle);
	}

	if ($last) {
		if ($name_whole) {
			$name_whole .= " ";
		}
		$name_whole .=  lc($last);
	}

	$name_whole  =~ s/ de / /;

	my $name_nomiddle = "";
	if ($name_whole =~ /^(.+)\s.+\s(.+)$/) {
		$name_nomiddle = $1 . " " . $2;
	} elsif ($name_whole =~ /^(.+)\s(.+)$/) {
		$name_nomiddle = $1 . " " . $2;
	} elsif ($name_whole =~ /^(.+)$/) {
		$name_nomiddle = $1;
	}

	return ($name_whole, $name_nomiddle);
}

#
# Return TRUE if the names, dates, etc for the two profiles match
#
sub profileBasicsMatch($$) {
	my $left_profile = shift;
	my $right_profile = shift;
	my $score = 0;

	(my $left_name_whole, my $left_name_nomiddle) = 
		cleanupNames($left_profile->gender,
			$left_profile->name_first,
			$left_profile->name_middle,
			$left_profile->name_last,
			$left_profile->name_maiden);

	(my $right_name_whole, my $right_name_nomiddle) =
		cleanupNames($right_profile->gender,
			$right_profile->name_first,
			$right_profile->name_middle,
			$right_profile->name_last,
			$right_profile->name_maiden);

	if ($left_name_whole ne $right_name_whole &&
		$left_name_nomiddle ne $right_name_nomiddle) {

		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(name): '%s' ne '%s'\n",
				$left_name_whole,
				$right_name_whole));
		# printDebug($DBG_MATCH_BASIC, "left_name_whole: $left_name_whole\n";
		# printDebug($DBG_MATCH_BASIC, "right_name_whole: $right_name_whole\n";
		# printDebug($DBG_MATCH_BASIC, "left_name_nomiddle: $left_name_nomiddle\n";
		# printDebug($DBG_MATCH_BASIC, "right_name_nomiddle: $right_name_nomiddle\n";
		return 0;
	}

	if ($left_profile->gender ne $right_profile->gender) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(gender): %s's '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->gender,
				$right_profile->gender));
		return 0;
	}

	if ($left_profile->living ne $right_profile->living) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(living): %s's '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->living,
				$right_profile->living));
		return 0;
	}

	if (!dateMatches($left_profile->death_year, $right_profile->death_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(death_date): %s's death year '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->death_year,
				$right_profile->death_year));
		return 0;
	}

	if (!dateMatches($left_profile->death_date, $right_profile->death_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(death_date): %s's death date '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->death_date,
				$right_profile->death_date));
		return 0;
	}

	if (!dateMatches($left_profile->birth_year, $right_profile->birth_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(birth_year): %s's birth year '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->birth_year,
				$right_profile->birth_year));
		return 0;
	}

	if (!dateMatches($left_profile->birth_date, $right_profile->birth_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(birth_date): %s's birth date '%s' does not equal '%s'\n",
				$left_name_whole,
				$left_profile->birth_date,
				$right_profile->birth_date));
		return 0;
	}

	# For females the maiden name must match
	if (lc($left_profile->gender) eq "female") {
		if ($left_profile->name_maiden ne "" &&
			$right_profile->name_maiden ne "" &&
			lc($left_profile->name_maiden) ne lc($right_profile->name_maiden)) {
			printDebug($DBG_MATCH_BASIC,
				sprintf("profileBasicsMatch(maiden): %s's '%s' does not equal '%s'\n",
					$left_name_whole,
					$left_profile->name_maiden,
					$right_profile->name_maiden));
			return 0;
		}
	}

	printDebug($DBG_MATCH_BASIC,
		sprintf("profileBasicsMatch(name): %s's basic profile data matches\n",
			$left_name_whole));
	return 1;
}

#
# Determine how many pages of pending merges there are.  There currently
# isn't a way to do this via the API so we screen scrape it from the html.
#
sub getMaxPage() {
	my $filename = "$env{'datadir'}/merge_issues_1.html";
	my $max_page = 1;

	printDebug($DBG_PROGRESS, "Determining the number of pages of pending merges...\n");
	getPage($filename, "http://www.geni.com/list/requested_merges?order=last_modified_at&direction=desc&include_collaborators=true&page=1");

	# Figure out how many pages of merge issues there are
	my $fh = createReadFH($filename);
 
	while(<$fh>) {
		if (/\/list\/requested_merges\?page=(\d+)/) {
	 		if ($1 > $max_page) {
				 $max_page = $1;
			}
		}
	}
	undef $fh;

	# The web page displays 20 per page, the json displays 50 so adjust max_page
	$max_page = $max_page * 20;
	$max_page = int($max_page/50);

	printDebug($DBG_PROGRESS,
		sprintf("There are %d merge issues spread over %d pages\n",
			$max_page * 50, $max_page));

	return ($max_page);
}

#
# Removing leading and trailing whitespaces in $string
#
sub removeMiscSpaces($) {
	my $string = shift;
	if ($string =~ /^\s+(.*)/) {
		$string = $1;
	}
	if ($string =~ /(.*)\s+$/) {
		$string = $1;
	}
	if ($string =~ /^\s+$/) {
		$string = "";
	}
	return $string;
}

sub comparePartners($$$) {
	my $partner_type	= shift;
	my $left_partners	= shift;
	my $right_partners	= shift;

	if (($left_partners && !$right_partners) || (!$left_partners && $right_partners)) { 
		return 1;
	}

	if ($left_partners ne $right_partners) { 
		printDebug($DBG_MATCH_BASIC, "Profile $partner_type DO NOT match.\n");

		printDebug($DBG_MATCH_BASIC, "Left Profile $partner_type:\n");
		foreach my $person (split(/:/, $left_partners)) {
			printDebug($DBG_MATCH_BASIC, "- $person\n");
		}

		printDebug($DBG_MATCH_BASIC, "Right Profile $partner_type:\n");
		foreach my $person (split(/:/, $right_partners)) {
			printDebug($DBG_MATCH_BASIC, "- $person\n");
		}

		return 0;
	}

	return 1;
}


sub compareProfiles($) {
	my $filename = shift;

	if (jsonSanityCheck($filename) == 0) {
		return 0;
	}

	my $fh = createReadFH($filename);
	my $json_data = <$fh>;
	my $json = new JSON;
	my $json_text = $json->allow_nonref->utf8->relaxed->decode($json_data);
	undef $fh;

	# printDebug($DBG_NONE, sprintf ("Pretty JSON:\n%s", $json->pretty->encode($json_text)));

	my $left_profile = new profile;
	my $right_profile= new profile;
	my $geni_profile = $left_profile;
	foreach my $json_profile (@{$json_text}) {

		# If the profile isn't on the big tree then don't merge it.
		# If the profile has a curator note it is probably a profile
		# subject to bad merges so don't merge it.
		if ($json_profile->{'focus'}->{'big_tree'} ne "true" ||
			$json_profile->{'focus'}->{'merge_note'} ne "") {
			return 0;
		}

		# Do not merge a profile managed by any of the blacklist_managers
                foreach my $profile_id (split(/,/, $json_profile->{'focus'}->{'managers'})) {
			if ($blacklist_managers{$profile_id}) {
				return 0;
			}
		}

		my $profile_id = $json_profile->{'focus'}->{'id'};
		$geni_profile->name_first(removeMiscSpaces($json_profile->{'focus'}->{'first_name'}));
		$geni_profile->name_middle(removeMiscSpaces($json_profile->{'focus'}->{'middle_name'}));
		$geni_profile->name_last(removeMiscSpaces($json_profile->{'focus'}->{'last_name'}));
		$geni_profile->name_maiden(removeMiscSpaces($json_profile->{'focus'}->{'maiden_name'}));
		$geni_profile->suffix(removeMiscSpaces($json_profile->{'focus'}->{'suffix'}));
		$geni_profile->gender($json_profile->{'focus'}->{'gender'});
		$geni_profile->living($json_profile->{'focus'}->{'living'});
		$geni_profile->death_date($json_profile->{'focus'}->{'death_date'});
		$geni_profile->death_year($json_profile->{'focus'}->{'death_year'});
		$geni_profile->birth_date($json_profile->{'focus'}->{'birth_date'});
		$geni_profile->birth_year($json_profile->{'focus'}->{'birth_year'});
		
		my %fathers_hash;
		my %mothers_hash;
		my %spouses_hash;
		foreach my $i (keys %{$json_profile->{'nodes'}}) {
			if ($i !~ /union/) {
				next;
			}

			my $partner_type = "";
			# The "partners" will be parents
			if ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "child") {
				$partner_type = "parents";

			# The "partners" will be spouses 
			} elsif ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "partner") {
				$partner_type = "spouses";
			}

			# So far spouse and ex_spouse are the only two types I've seen
			my $union_type = $json_profile->{'nodes'}->{$i}->{'status'};
			if ($union_type ne "spouse" && $union_type ne "ex_spouse") {
				next;
			}
			
			foreach my $j (keys %{$json_profile->{'nodes'}->{$i}->{'edges'}}) {
				# The profile that we are analyzing will be listed in the union,
				# just skip over it
				if ($j eq "profile-$profile_id") {
					next;
				}

				# We're ignoring children and siblings for now
				my $rel = $json_profile->{'nodes'}->{$i}->{'edges'}->{$j}->{'rel'};
				if ($rel ne "partner") {
					next;
				}

				my $name = lc($json_profile->{'nodes'}->{$j}->{'name'});
				if ($partner_type eq "parents") {
					if ($json_profile->{'nodes'}->{$j}->{'gender'} eq "male") {
						$fathers_hash{$name} = 1;
					} elsif ($json_profile->{'nodes'}->{$j}->{'gender'} eq "female") {
						$mothers_hash{$name} = 1;
					}
				} elsif ($partner_type eq "spouses") {
					$spouses_hash{$name} = 1;
				}
			}
		}
	
		my @fathers_array;
		foreach my $i (sort keys %fathers_hash) {
			push @fathers_array, $i;
		}

		my @mothers_array;
		foreach my $i (sort keys %mothers_hash) {
			push @mothers_array, $i;
		}

		my @spouses_array;
		foreach my $i (sort keys %spouses_hash) {
			push @spouses_array, $i;
		}
	
		$geni_profile->fathers(join(":", @fathers_array));
		$geni_profile->mothers(join(":", @mothers_array));
		$geni_profile->spouses(join(":", @spouses_array));
		$geni_profile = $right_profile;
	}

	if (profileBasicsMatch($left_profile, $right_profile) == 0) {
		return 0;
	}

	# printf "Fathers:\n";
	# printf "-left  : %s\n", $left_profile->fathers;
	# printf "-right : %s\n", $right_profile->fathers;

	# printf "Mothers:\n";
	# printf "-left  : %s\n", $left_profile->mothers;
	# printf "-right : %s\n", $right_profile->mothers;

	# printf "Spouses:\n";
	# printf "-left  : %s\n", $left_profile->spouses;
	# printf "-right : %s\n", $right_profile->spouses;

        if (!comparePartners("fathers", $left_profile->fathers, $right_profile->fathers)) {
		return 0;
	}

        if (!comparePartners("mothers", $left_profile->mothers, $right_profile->mothers)) {
		return 0;
	}

        if (!comparePartners("spouses", $left_profile->spouses, $right_profile->spouses)) {
		return 0;
	}

	printDebug($DBG_MATCH_BASIC, "Profile parents/spouses DO match\n");
	return 1;
}

#
# Update the get_history file with the current timestamp
#
sub updateGetHistory() {
	# todo: add this timestamp to get_history
	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	my $get_history_fh = createWriteFH("", $env{'history_file'}, 1);
	print $get_history_fh "$time_sec.$time_usec\n";
	undef $get_history_fh;
}

sub analyzePendingMerge($$$$) {
	my $profiles_url	= shift;
	my $merge_url_api	= shift;
	my $id1			= shift;
	my $id2			= shift;

	my $filename = sprintf("$env{'datadir'}/%s-%s.json", $id1, $id2);

	# The only time these will be blank is if the user runs the script on one
	# specific merge via the command line. The format for the urls are:
	#
	# profiles":"http://www.geni.com/api/profiles/compare/6000000001544613257,6000000009512261247"
	# merge_url":"http://www.geni.com/api/profiles/merge/6000000001544613257,6000000009512261247"
	if ($profiles_url eq "" || $merge_url_api eq "") {
		$profiles_url = "http://www.geni.com/api/profiles/compare/$id1,$id2";
		$merge_url_api = "http://www.geni.com/api/profiles/merge/$id1,$id2";
	}

	# http://www.geni.com/merge/compare/6000000004086345876?return=merge_center&to=5659624823800046253
	my $merge_url_html = "<a href=\"http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2\">http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2</a>";
	printDebug($DBG_NONE, "$merge_url_html\n");
	getPage($filename, $profiles_url);

	if (compareProfiles($filename)) {
		(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);
		my $merge_log_entry =
			sprintf("%s : %4d-%02d-%02d %02d:%02d:%02d : %s",
				$env{'username'}, $year+1900, $mon+1, $mday,
				$hour, $min, $sec, $merge_url_html);
		$env{'matches'}++;
		printDebug($DBG_PROGRESS, "MERGING: $id1 and $id2\n");
		printf $merge_log_fh "$merge_log_entry\n";
		$m->post($merge_url_api);
		updateGetHistory();
	}
}

#
# Loop through every page of pending merges and analyze all
# merges listed on each page. This can take days....
#
sub traversePendingMergePages($$) {
	my $range_begin	= shift;
	my $range_end	= shift;
	my $max_page	= getMaxPage();

	if ($range_end > $max_page || !$range_end) {
		$range_end = $max_page;
	}

	if (!$range_begin) {
		$range_begin = 1;

		for (my $i = 1; $i <= $range_end; $i++) {
			if (-e "$env{'datadir'}/merge_list_$i.json") {
				$range_begin = $i;
			}
		}

		printDebug($DBG_PROGRESS, "First Page: $range_begin\n");
	}


	for (my $i = $range_begin; $i <= $range_end; $i++) {
		my $loop_start_time = time();
		my $page_profile_count = 0;
		my $filename = "$env{'datadir'}/merge_list_$i.json";
		printDebug($DBG_PROGRESS, "Downloading pending merges list...\n");

		getPage($filename, "http://www.geni.com/api/profiles/merges?collaborators=true&order=last_modified_at&direction=asc&page=$i");

		if (jsonSanityCheck($filename) == 0) {
			# todo: delete the file
			next;
		}

		my $fh = createReadFH($filename);
		my $json_data = <$fh>;
		my $json = new JSON;
		my $json_text = $json->allow_nonref->utf8->relaxed->decode($json_data);
		undef $fh;

		foreach my $json_profile_pair (@{$json_text}) {
			my $profiles_url	= $json_profile_pair->{'profiles'};
			my $merge_url_api	= $json_profile_pair->{'merge_url'};
			$env{'profiles'}++;
			$page_profile_count++;
			printDebug($DBG_PROGRESS, "Page $i/$range_end Profile $page_profile_count: Overall Profile $env{'profiles'}\n");
			printDebug($DBG_NONE, "<a href=\"$profiles_url\">$profiles_url</a>\n" );
			printDebug($DBG_URLS, "merge_url_api: $merge_url_api\n" );

			if ($profiles_url =~ /\/(\d+),(\d+)$/) {
				analyzePendingMerge($profiles_url, $merge_url_api, $1, $2);
			}
			printDebug($DBG_NONE, "\n");
		} # End of json_profile_pair for loop

		my $loop_end_time = time();
		my $loop_run_time = $loop_end_time - $loop_start_time;
		printDebug($DBG_NONE,
			sprintf("Run time for page $i: %02d:%02d:%02d\n",
				int($loop_run_time/3600),
				int(($loop_run_time % 3600) / 60),
				int($loop_run_time % 60)));
		printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles so far\n");

	} # End of range_begin/range_end for loop

	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles in $range_end pages\n");
}


sub main() {
	$env{'username'}	= "";
	$env{'password'}	= "";
	my $range_begin		= 0;
	my $range_end		= 0;
	my $left_id		= 0;
	my $right_id		= 0;

	#
	# Parse all command line arguements
	#
	for (my $i = 0; $i <= $#ARGV; $i++) {
		if ($ARGV[$i] eq "-u" || $ARGV[$i] eq "-username") {
			$env{'username'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-p" || $ARGV[$i] eq "-password") {
			$env{'password'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-c" || $ARGV[$i] eq "-circa") {
			$env{'circa_range'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-pm" || $ARGV[$i] eq "-pendingmerge") {
			$left_id = $ARGV[++$i];
			$right_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-rb") {
			$range_begin = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-re") {
			$range_end = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-api_get_timeframe") {
			$env{'get_timeframe'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-api_get_limit") {
			$env{'get_limit'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-h" || $ARGV[$i] eq "-help") {
			printHelp();

		} else { 
			printDebug($DBG_NONE, "ERROR: '$ARGV[$i]' is not a supported arguement\n");
			printHelp();
		}
	}

	if (!$env{'username'}) {
		print STDERR "\nERROR: username is blank.  You must specify your geni username via '-u username'\n";
		exit();
	}

	if (!$env{'password'}) {
		print STDERR "\nERROR: password is blank.  You must specify your geni password via '-p password'\n";
		exit();
	}

	if (($left_id && !$right_id) || (!$left_id && $right_id)) {
		print STDERR "\nERROR: You must specify two profile IDs, you only specified one\n";
		exit();
	}

	print $merge_log_fh "<pre>";
	print $debug_fh "<pre>";
	# geniLoginAPI(); # Go ahead and login so the user will know now if they mistyped their password
	geniLogin(); # Go ahead and login so the user will know now if they mistyped their password
	if ($left_id && $right_id) {
		analyzePendingMerge("", "", $left_id, $right_id);
	} else {
		traversePendingMergePages($range_begin, $range_end);
	}
	geniLogout();

	my $end_time = time();
	my $run_time = $end_time - $env{'start_time'};
	printDebug($DBG_NONE,
		sprintf("Total running time: %02d:%02d:%02d\n",
			int($run_time/3600),
			int(($run_time % 3600) / 60),
			int($run_time % 60)));

	print $merge_log_fh "</pre>";
	undef $merge_log_fh;
	print $debug_fh "</pre>";
	undef $debug_fh;
}

__END__
46,805,758 big tree profiles on 10/29/2010

DONE
- better debugs
- File IO module
- functions from work script
- measure how many req we did in the last 10 seconds

TODO
- remove 'sir', 'president', 'knight', 'of' from comparisons
- write wiki
