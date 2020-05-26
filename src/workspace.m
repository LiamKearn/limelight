#include "workspace.h"

extern struct event_loop g_event_loop;

void workspace_event_handler_init(void **context)
{
    workspace_context *ws_context = [workspace_context alloc];
    *context = ws_context;
}

void workspace_event_handler_begin(void **context)
{
    workspace_context *ws_context = *context;
    [ws_context init];
}

void workspace_event_handler_end(void *context)
{
    workspace_context *ws_context = (workspace_context *) context;
    [ws_context dealloc];
}

void workspace_application_observe_finished_launching(void *context, struct process *process)
{
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:((struct process *)process)->pid];
    if (application) {
        [application addObserver:context forKeyPath:@"finishedLaunching" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:process];
    } else {
        debug("%s: could not subscribe to activation policy changes for %s (%d)\n", __FUNCTION__, process->name, process->pid);
    }
}

void workspace_application_observe_activation_policy(void *context, struct process *process)
{
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:process->pid];
    if (application) {
        [application addObserver:context forKeyPath:@"activationPolicy" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:process];
    } else {
        debug("%s: could not subscribe to finished launching changes for %s (%d)\n", __FUNCTION__, process->name, process->pid);
    }
}

bool workspace_application_is_observable(struct process *process)
{
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:process->pid];

    if (application) {
        bool result = [application activationPolicy] != NSApplicationActivationPolicyProhibited;
        [application release];
        return result;
    }

    debug("%s: could not determine observability status for %s (%d)\n", __FUNCTION__, process->name, process->pid);
    return false;
}

bool workspace_application_is_finished_launching(struct process *process)
{
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:process->pid];

    if (application) {
        bool result = [application isFinishedLaunching] == YES;
        [application release];
        return result;
    }

    debug("%s: could not determine launch status for %s (%d)\n", __FUNCTION__, process->name, process->pid);
    return false;
}

@implementation workspace_context
- (id)init
{
    if ((self = [super init])) {
       [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(activeDisplayDidChange:)
                name:@"NSWorkspaceActiveDisplayDidChangeNotification"
                object:nil];

       [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(activeSpaceDidChange:)
                name:NSWorkspaceActiveSpaceDidChangeNotification
                object:nil];

       [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(didHideApplication:)
                name:NSWorkspaceDidHideApplicationNotification
                object:nil];

       [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(didUnhideApplication:)
                name:NSWorkspaceDidUnhideApplicationNotification
                object:nil];

       [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(didWake:)
                name:NSWorkspaceDidWakeNotification
                object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"activationPolicy"]) {
        id result = [change objectForKey:NSKeyValueChangeNewKey];
        if ([result intValue] != NSApplicationActivationPolicyProhibited) {
            struct process *process = context;
            assert(!process->terminated);

            debug("%s: activation policy changed for %s (%d)\n", __FUNCTION__, process->name, process->pid);
            struct event *event = event_create(&g_event_loop, APPLICATION_LAUNCHED, process);
            event_loop_post(&g_event_loop, event);

            //
            // NOTE(koekeishiya): For some stupid reason it is possible to get notified by the system
            // about a change, and NOT being able to remove ourselves from observation because
            // it claims that we are not observing the key-path, but we clearly are, as we would
            // otherwise not be here in the first place..
            //

            @try {
                [object removeObserver:self forKeyPath:@"activationPolicy"];
            } @catch (NSException * __unused exception) {}

            [object release];
        }
    }

    if ([keyPath isEqualToString:@"finishedLaunching"]) {
        id result = [change objectForKey:NSKeyValueChangeNewKey];
        if ([result intValue] == 1) {
            struct process *process = context;
            assert(!process->terminated);

            debug("%s: %s (%d) finished launching\n", __FUNCTION__, process->name, process->pid);
            struct event *event = event_create(&g_event_loop, APPLICATION_LAUNCHED, process);
            event_loop_post(&g_event_loop, event);

            //
            // NOTE(koekeishiya): For some stupid reason it is possible to get notified by the system
            // about a change, and NOT being able to remove ourselves from observation because
            // it claims that we are not observing the key-path, but we clearly are, as we would
            // otherwise not be here in the first place..
            //

            @try {
                [object removeObserver:self forKeyPath:@"finishedLaunching"];
            } @catch (NSException * __unused exception) {}

            [object release];
        }
    }
}

- (void)didWake:(NSNotification *)notification
{
    struct event *event = event_create(&g_event_loop, SYSTEM_WOKE, NULL);
    event_loop_post(&g_event_loop, event);
}

- (void)activeDisplayDidChange:(NSNotification *)notification
{
    struct event *event = event_create(&g_event_loop, DISPLAY_CHANGED, NULL);
    event_loop_post(&g_event_loop, event);
}

- (void)activeSpaceDidChange:(NSNotification *)notification
{
    struct event *event = event_create(&g_event_loop, SPACE_CHANGED, NULL);
    event_loop_post(&g_event_loop, event);
}

- (void)didHideApplication:(NSNotification *)notification
{
    pid_t pid = [[notification.userInfo objectForKey:NSWorkspaceApplicationKey] processIdentifier];
    struct event *event = event_create(&g_event_loop, APPLICATION_HIDDEN, (void *)(intptr_t) pid);
    event_loop_post(&g_event_loop, event);
}

- (void)didUnhideApplication:(NSNotification *)notification
{
    pid_t pid = [[notification.userInfo objectForKey:NSWorkspaceApplicationKey] processIdentifier];
    struct event *event = event_create(&g_event_loop, APPLICATION_VISIBLE, (void *)(intptr_t) pid);
    event_loop_post(&g_event_loop, event);
}

@end
