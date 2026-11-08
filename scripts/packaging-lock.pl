#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock :mode);

my ($path, @command) = @ARGV;
my $checking = defined($path) && $path eq '--check';
my $lease;
if ($checking) {
    ($path, my $fd, my $owner) = @command;
    die "Packaging lease was not inherited from the lock wrapper\n"
        unless defined($path) && defined($fd) && $fd =~ /^\d+$/ && $fd >= 3
            && defined($owner) && $owner =~ /^\d+$/ && $owner == getppid();
    open($lease, '+<&=', $fd) or die "Packaging lease descriptor is missing\n";
} else {
    die "Missing packaging lock or command\n" unless defined($path) && @command;
    sysopen($lease, $path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600)
        or die "Cannot open packaging lock safely: $!\n";
}
my @held = stat($lease);
my @named = lstat($path);
die "Packaging lock must be an owned regular file, not a link\n"
    unless @held && @named && S_ISREG($held[2]) && S_ISREG($named[2])
        && $held[4] == $< && $held[3] == 1 && $held[0] == $named[0] && $held[1] == $named[1];
chmod(0600, $lease) or die "Cannot protect packaging lock: $!\n";
flock($lease, LOCK_EX | LOCK_NB) or die "Another build or install is in progress. Try again after it finishes.\n";
@named = lstat($path);
die "Packaging lock path changed during acquisition\n"
    unless @named && S_ISREG($named[2]) && $held[0] == $named[0] && $held[1] == $named[1];
exit 0 if $checking;
truncate($lease, 0) or die "Cannot write packaging lock: $!\n";
print {$lease} "$$\n";
# Unlike the production app lock, the packaging lease deliberately survives
# exec and is inherited by active tools. There is no wrapper-only supervisor:
# if the shell dies while a copy/compiler is still running, that child keeps
# the lease until its operation has actually stopped.
fcntl($lease, F_SETFD, 0) or die "Cannot pass packaging lease to the command: $!\n";
$ENV{HUB_PACKAGING_LEASE_FD} = fileno($lease);
$ENV{HUB_PACKAGING_LEASE_PID} = $$;
exec @command;
die "Could not run packaging command: $!\n";
