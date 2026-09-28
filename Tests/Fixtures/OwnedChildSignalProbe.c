// Inert subprocess fixture: observes launch signal state and waits for one
// immediately exiting child through SIGCHLD, like an async process reaper.
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t child_signal = 0;
static void observed_child(int number) { (void)number; child_signal = 1; }
int main(int argc, char **argv) {
    sigset_t mask;
    sigprocmask(SIG_BLOCK, NULL, &mask);
    const int signals[] = {SIGCHLD, SIGTERM, SIGINT, SIGPIPE};
    int blocked = 0, nondefault = 0;
    for (int index = 0; index < 4; ++index) {
        struct sigaction disposition;
        sigaction(signals[index], NULL, &disposition);
        if (sigismember(&mask, signals[index])) blocked |= 1 << index;
        if (disposition.sa_handler != SIG_DFL) nondefault |= 1 << index;
    }
    printf("blocked=%d nondefault=%d\n", blocked, nondefault);
    fflush(stdout);
    if (blocked || nondefault || argc != 2 || strcmp(argv[1], "wait") != 0) return blocked || nondefault;
    struct sigaction action = {0};
    action.sa_handler = observed_child;
    sigemptyset(&action.sa_mask);
    sigaction(SIGCHLD, &action, NULL);
    sigset_t pending, previous;
    sigemptyset(&pending); sigaddset(&pending, SIGCHLD);
    sigprocmask(SIG_BLOCK, &pending, &previous);
    pid_t child = fork();
    if (child == 0) _exit(23);
    if (child < 0) return 2;
    while (!child_signal) sigsuspend(&previous);
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return 3;
    printf("observed_sigchld=%d child_exit=%d\n", child_signal, WEXITSTATUS(status));
    return WEXITSTATUS(status) == 23 ? 0 : 4;
}
