/* Copyright 2011-2015 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * A helper class that automatically loads and sorts {@link Email} in a {@link Folder} into
 * {@link Conversation}s ordered by date received (descending).
 *
 * Before starting, the application should subscribe to ConversationMonitor's various signals to
 * be informed of conversations being added and removed from the folder.  The application can
 * specify the minimum number of conversations to be held by ConversationMonitor by adjusting the
 * {@link min_window_count} property.
 */

public class Geary.App.ConversationMonitor : BaseObject {
    /**
     * These are the fields Conversations require to thread emails together.  These fields will
     * be retrieved regardless of the Field parameter passed to the constructor.
     */
    public const Geary.Email.Field REQUIRED_FIELDS =
        Geary.Email.Field.FLAGS | Geary.Email.Field.DATE | Geary.Email.Field.PROPERTIES;
    
    // An approximate multipler of messages-in-folder-to-conversation ... because the Engine doesn't
    // offer a way to directly load conversations in a folder as a vector unto itself, this class
    // loads a number of messages equal to the number of needed conversations times this multiplier
    private const int MSG_CONV_MULTIPLIER = 2;
    
    // # of messages to load at a time as we attempt to fill the min window.
    private const int MIN_FILL_MESSAGE_COUNT = 5 * MSG_CONV_MULTIPLIER;
    
    private const Geary.SpecialFolderType[] BLACKLISTED_FOLDER_TYPES = {
        Geary.SpecialFolderType.SPAM,
        Geary.SpecialFolderType.TRASH,
        Geary.SpecialFolderType.DRAFTS,
    };
    
    // Used when searching for associated emails ... this gets around threading / locking problems
    // by holding and generating private copies of all data; it also generates the search blacklist
    // at instance time, meaning if the paths change the most current set are always used
    private class SearchPredicateInstance : BaseObject {
        public FolderPath this_folder_path;
        public Email.Field required_fields;
        public Gee.HashSet<FolderPath?> path_blacklist = new Gee.HashSet<FolderPath?>();
        
        public SearchPredicateInstance(Folder folder, Email.Field required_fields) {
            this_folder_path = folder.path;
            this.required_fields = required_fields;
            
            // generate FolderPaths for the blacklisted special folder types
            foreach (Geary.SpecialFolderType type in BLACKLISTED_FOLDER_TYPES) {
                try {
                    Geary.Folder? blacklist_folder = folder.account.get_special_folder(type);
                    if (blacklist_folder != null)
                        path_blacklist.add(blacklist_folder.path);
                } catch (Error e) {
                    debug("Error finding special folder %s on account %s: %s",
                        type.to_string(), folder.account.to_string(), e.message);
                }
            }
            
            // Add "no folders" so we omit results that have been deleted permanently from the server.
            path_blacklist.add(null);
        }
        
        // NOTE: This is called from a background thread.
        public bool search_predicate(EmailIdentifier email_id, Email.Field fields,
            Gee.Collection<FolderPath?> known_paths, EmailFlags? flags) {
            // don't want partial emails
            if (!fields.fulfills(required_fields))
                return false;
            
            // if email is in this path, it's not blacklisted (i.e. if viewing the Spam folder, don't
            // blacklist because it's in the Spam folder, if viewing Drafts folder, display drafts)
            if (known_paths.contains(this_folder_path))
                return true;
            
            // Don't add drafts (unless in Drafts folder, above)
            if (flags != null && flags.contains(EmailFlags.DRAFT))
                return false;
            
            // If in a blacklisted path, don't add
            foreach (FolderPath? blacklisted_path in path_blacklist) {
                if (known_paths.contains(blacklisted_path))
                    return false;
            }
            
            return true;
        }
    }
    
    public Geary.Folder folder { get; private set; }
    
    public bool is_monitoring { get; private set; default = false; }
    
    public int min_window_count { get { return _min_window_count; }
        set {
            if (_min_window_count == value)
                return;
            
            _min_window_count = value;
            operation_queue.add(new FillWindowOperation(this, false));
        }
    }
    
    /**
     * Indicates that all mail in the primary {@link folder} has been loaded.
     */
    public bool all_mail_loaded { get; private set; default = false; }
    
    public Geary.ProgressMonitor progress_monitor { get { return operation_queue.progress_monitor; } }
    
    private Geary.Email.Field required_fields;
    private Geary.Folder.OpenFlags open_flags;
    private Cancellable? cancellable_monitor = null;
    private int _min_window_count = 0;
    private ConversationOperationQueue operation_queue = new ConversationOperationQueue();
    
    // All generated Conversations
    private Gee.HashSet<Conversation> conversations = new Gee.HashSet<Conversation>();
    
    // A map of all EmailIdentifiers to Conversations ... since emails from deep in the folder can
    // be added to a conversation, use primary_email_id_to_conversation for finding boundaries
    private Gee.HashMap<EmailIdentifier, Conversation> all_email_id_to_conversation =
        new Gee.HashMap<EmailIdentifier, Conversation>();
    
    // A map of primary EmailIdentifiers to Conversations ... primary ids come from ranged listing
    // and don't include ids found "deep" in the folder or from other folders
    private Gee.HashMap<EmailIdentifier, Conversation> primary_email_id_to_conversation =
        new Gee.HashMap<EmailIdentifier, Conversation>();
    
    /**
     * "monitoring-started" is fired when the Conversations folder has been opened for monitoring.
     */
    public virtual signal void monitoring_started() {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::monitoring_started",
            folder.to_string());
    }
    
    /**
     * "monitoring-stopped" is fired when the Geary.Folder object has closed (either due to error
     * or user) and the Conversations object is therefore unable to continue monitoring.
     */
    public virtual signal void monitoring_stopped() {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::monitoring_stopped",
            folder.to_string());
    }
    
    /**
     * "scan-started" is fired whenever beginning to load messages into the Conversations object.
     *
     * Note that more than one load can be initiated, due to Conversations being completely
     * asynchronous.  "scan-started", "scan-error", and "scan-completed" will be fired (as
     * appropriate) for each individual load request; that is, there is no internal counter to ensure
     * only a single "scan-completed" is fired to indicate multiple loads have finished.
     */
    public virtual signal void scan_started() {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::scan_started",
            folder.to_string());
    }
    
    /**
     * "scan-error" is fired when an Error is encounted while loading messages.  It will be followed
     * by a "scan-completed" signal.
     */
    public virtual signal void scan_error(Error err) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::scan_error %s",
            folder.to_string(), err.message);
    }
    
    /**
     * "scan-completed" is fired when the scan of the email has finished.
     */
    public virtual signal void scan_completed(bool conversations_added) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::scan_completed conversations_added=%s",
            folder.to_string(), conversations_added.to_string());
    }
    
    /**
     * "conversations-added" indicates that one or more new Conversations have been detected while
     * processing email, either due to a user-initiated load request or due to monitoring.
     */
    public virtual signal void conversations_added(Gee.Collection<Conversation> conversations) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::conversations_added %d",
            folder.to_string(), conversations.size);
    }
    
    /**
     * "conversations-removed" is fired when all the email in a Conversation has been removed.
     * It's possible this will be called without a signal alerting that it's emails have been
     * removed, i.e. a "conversation-removed" signal may fire with no accompanying
     * "conversation-trimmed".
     *
     * Note that this can only occur when monitoring is enabled.  There is (currently) no
     * user call to manually remove email from Conversations.
     */
    public virtual signal void conversation_removed(Conversation conversation) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::conversation_removed",
            folder.to_string());
    }
    
    /**
     * "conversation-appended" is fired when one or more Email objects have been added to the
     * specified Conversation.  This can happen due to a user-initiated load or while monitoring
     * the Folder.
     */
    public virtual signal void conversation_appended(Conversation conversation,
        Gee.Collection<Geary.Email> email) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::conversation_appended",
            folder.to_string());
    }
    
    /**
     * "conversation-trimmed" is fired when one or more Emails have been removed from the Folder,
     * and therefore from the specified Conversation.  If the trimmed Email is the last usable
     * Email in the Conversation, this signal will be followed by "conversation-removed".  However,
     * it's possible for "conversation-removed" to fire without "conversation-trimmed" preceding
     * it, in the case of all emails being removed from a Conversation at once.
     *
     * There is (currently) no user-specified call to manually remove Email from Conversations.
     * This is only called when monitoring is enabled.
     */
    public virtual signal void conversation_trimmed(Conversation conversation,
        Gee.Collection<Geary.Email> email) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::conversation_trimmed",
            folder.to_string());
    }
    
    /**
     * "email-flags-changed" is fired when the flags of an email in a conversation have changed,
     * as reported by the monitored folder.  The local copy of the Email is updated and this
     * signal is fired.
     *
     * Note that if the flags of an email not captured by the Conversations object change, no signal
     * is fired.  To know of all changes to all flags, subscribe to the Geary.Folder's
     * "email-flags-changed" signal.
     */
    public virtual signal void email_flags_changed(Conversation conversation, Geary.Email email) {
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::email_flag_changed",
            folder.to_string());
    }
    
    /**
     * Fired when the known paths of {@link Email} have changed, either added or removed.
     */
    public virtual signal void email_paths_changed(Conversation conversation,
        Gee.Collection<Geary.EmailIdentifier> ids) {
    }
    
    /**
     * Creates a conversation monitor for the given folder.
     *
     * @param folder Folder to monitor
     * @param open_flags See {@link Geary.Folder}
     * @param required_fields See {@link Geary.Folder}
     * @param min_window_count Minimum number of conversations that will be loaded
     */
    public ConversationMonitor(Geary.Folder folder, Geary.Folder.OpenFlags open_flags,
        Geary.Email.Field required_fields, int min_window_count) {
        this.folder = folder;
        this.open_flags = open_flags;
        this.required_fields = required_fields | REQUIRED_FIELDS | Account.ASSOCIATED_REQUIRED_FIELDS;
        _min_window_count = min_window_count;
    }
    
    ~ConversationMonitor() {
        if (is_monitoring)
            debug("Warning: Conversations object destroyed without stopping monitoring");
        
        clear();
    }
    
    protected virtual void notify_monitoring_started() {
        monitoring_started();
    }
    
    protected virtual void notify_monitoring_stopped() {
        monitoring_stopped();
    }
    
    protected virtual void notify_scan_started() {
        scan_started();
    }
    
    protected virtual void notify_scan_error(Error err) {
        scan_error(err);
    }
    
    protected virtual void notify_scan_completed(bool conversations_added) {
        scan_completed(conversations_added);
    }
    
    protected virtual void notify_conversations_added(Gee.Collection<Conversation> conversations) {
        conversations_added(conversations);
    }
    
    protected virtual void notify_conversation_removed(Conversation conversation) {
        conversation_removed(conversation);
    }
    
    protected virtual void notify_conversation_appended(Conversation conversation,
        Gee.Collection<Geary.Email> emails) {
        conversation_appended(conversation, emails);
    }
    
    protected virtual void notify_conversation_trimmed(Conversation conversation,
        Gee.Collection<Geary.Email> emails) {
        conversation_trimmed(conversation, emails);
    }
    
    protected virtual void notify_email_flags_changed(Conversation conversation, Geary.Email email) {
        email_flags_changed(conversation, email);
    }
    
    protected virtual void notify_email_paths_changed(Conversation conversation,
        Gee.Collection<Geary.EmailIdentifier> ids) {
        email_paths_changed(conversation, ids);
    }
    
    public int get_conversation_count() {
        return conversations.size;
    }
    
    public int get_email_count() {
        return all_email_id_to_conversation.size;
    }
    
    public Gee.Collection<Conversation> get_conversations() {
        return conversations.read_only_view;
    }
    
    public Geary.App.Conversation? get_conversation_for_email(Geary.EmailIdentifier email_id) {
        return all_email_id_to_conversation[email_id];
    }
    
    public async bool start_monitoring_async(Cancellable? cancellable = null)
        throws Error {
        if (is_monitoring)
            return false;
        
        // set before yield to guard against reentrancy
        is_monitoring = true;
        
        cancellable_monitor = cancellable;
        
        // Double check that the last run of the queue got stopped and that
        // it's empty.
        if (operation_queue.is_processing)
            yield operation_queue.stop_processing_async(cancellable_monitor);
        operation_queue.clear();
        
        // Add the initial local load ahead of anything the Folder might notify us of
        // (additions, removals, etc.) to prime the pump
        operation_queue.add(new FillWindowOperation(this, false));
        
        connect_to_folder();
        
        try {
            yield folder.open_async(open_flags, cancellable);
        } catch (Error err) {
            is_monitoring = false;
            
            disconnect_from_folder();
            
            throw err;
        }
        
        notify_monitoring_started();
        
        // Process operations in the background.
        operation_queue.run_process_async.begin();
        
        return true;
    }
    
    /**
     * Halt monitoring of the Folder and, if specified, close it.  Note that the Cancellable
     * supplied to start_monitoring_async() is used during monitoring but *not* for this method.
     * If null is supplied as the Cancellable, no cancellable is used; pass the original Cancellable
     * here to use that.
     *
     * Returns a result code that is semantically identical to the result of
     * {@link Geary.Folder.close_async}.
     */
    public async bool stop_monitoring_async(Cancellable? cancellable) throws Error {
        if (!is_monitoring)
            return false;
        
        yield operation_queue.stop_processing_async(cancellable);
        
        // set now to prevent reentrancy during yield or signal
        is_monitoring = false;
        
        disconnect_from_folder();
        
        bool closing = false;
        Error? close_err = null;
        try {
            closing = yield folder.close_async(cancellable);
        } catch (Error err) {
            // throw, but only after cleaning up (which is to say, if close_async() fails,
            // then the Folder is still treated as closed, which is the best that can be
            // expected; it definitely shouldn't still be considered open).
            debug("Unable to close monitored folder %s: %s", folder.to_string(), err.message);
            
            close_err = err;
        }
        
        notify_monitoring_stopped();
        
        clear();
        
        if (close_err != null)
            throw close_err;
        
        return closing;
    }
    
    private void clear() {
        foreach (Conversation conversation in conversations)
            conversation.clear_owner();
        
        conversations.clear();
        all_email_id_to_conversation.clear();
        primary_email_id_to_conversation.clear();
    }
    
    private void connect_to_folder() {
        folder.email_appended.connect(on_folder_email_appended);
        folder.email_inserted.connect(on_folder_email_inserted);
        folder.email_removed.connect(on_folder_email_removed);
        folder.opened.connect(on_folder_opened);
        folder.account.email_flags_changed.connect(on_account_email_flags_changed);
        folder.account.email_locally_complete.connect(on_account_email_locally_complete);
        folder.account.email_appended.connect(on_account_email_appended);
        folder.account.email_discovered.connect(on_account_email_discovered);
        folder.account.email_inserted.connect(on_account_email_inserted);
        folder.account.email_removed.connect(on_account_email_removed);
    }
    
    private void disconnect_from_folder() {
        folder.email_appended.disconnect(on_folder_email_appended);
        folder.email_inserted.disconnect(on_folder_email_inserted);
        folder.email_removed.disconnect(on_folder_email_removed);
        folder.opened.disconnect(on_folder_opened);
        folder.account.email_flags_changed.disconnect(on_account_email_flags_changed);
        folder.account.email_locally_complete.disconnect(on_account_email_locally_complete);
        folder.account.email_appended.disconnect(on_account_email_appended);
        folder.account.email_discovered.disconnect(on_account_email_discovered);
        folder.account.email_inserted.disconnect(on_account_email_inserted);
        folder.account.email_removed.disconnect(on_account_email_removed);
    }
    
    // By passing required_fields, this forces the email to be downloaded (if not already) at the
    // potential expense of loading it twice; use Email.Field.NONE to only load the email identifiers
    // and potentially not be able to load the email due to unavailability (but will be loaded
    // later when locally-available)
    private async void load_by_id_async(Geary.EmailIdentifier? initial_id, int count, Email.Field fields,
        Geary.Folder.ListFlags flags, Cancellable? cancellable) {
        int start_conversations = get_conversation_count();
        
        notify_scan_started();
        try {
            yield process_email_async(folder.path,
                yield folder.list_email_by_id_async(initial_id, count, fields, flags, cancellable),
                cancellable);
        } catch (Error err) {
            notify_scan_error(err);
        } finally {
            notify_scan_completed(start_conversations < get_conversation_count());
        }
    }
    
    // See note at load_by_id_async for how Email.Field should be treated by caller
    private async void load_by_sparse_id(Gee.Collection<Geary.EmailIdentifier> ids, Email.Field fields,
        Geary.Folder.ListFlags flags, Cancellable? cancellable) {
        int start_conversations = get_conversation_count();
        
        notify_scan_started();
        try {
            yield process_email_async(folder.path,
                yield folder.list_email_by_sparse_id_async(ids, fields, flags, cancellable),
                cancellable);
        } catch (Error err) {
            notify_scan_error(err);
        } finally {
            notify_scan_completed(start_conversations < get_conversation_count());
        }
    }
    
    private async void load_associations_async(FolderSupport.Associations supports_associations,
        Geary.EmailIdentifier? low_id, int count, Cancellable? cancellable) {
        int start_conversations = get_conversation_count();
        
        notify_scan_started();
        
        SearchPredicateInstance predicate_instance = new SearchPredicateInstance(folder, required_fields);
        
        Gee.Collection<AssociatedEmails>? associations = null;
        Gee.Collection<EmailIdentifier> primary_email_ids = new Gee.HashSet<EmailIdentifier>();
        try {
            associations = yield supports_associations.local_list_associated_emails_async(
                low_id, count, required_fields, predicate_instance.search_predicate, primary_email_ids,
                all_email_id_to_conversation.keys, cancellable);
        } catch (Error err) {
            debug("Unable to load associated emails from %s: %s", supports_associations.to_string(),
                err.message);
            notify_scan_error(err);
        }
        
        if (associations != null && associations.size > 0) {
            process_associations(supports_associations.path, associations, primary_email_ids,
                cancellable);
        }
        
        notify_scan_completed(start_conversations < get_conversation_count());
    }
    
    private async void process_email_async(FolderPath path, Gee.Collection<Geary.Email>? emails,
        Cancellable? cancellable) {
        if (emails == null || emails.size == 0)
            return;
        
        Gee.Set<EmailIdentifier> ids = traverse<Email>(emails)
            .map<EmailIdentifier>(email => email.id)
            .to_hash_set();
        
        yield process_email_ids_async(path, ids, cancellable);
    }
    
    private async void process_email_ids_async(FolderPath path, Gee.Collection<Geary.EmailIdentifier>? email_ids,
        Cancellable? cancellable) {
        if (email_ids == null || email_ids.size == 0)
            return;
        
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::process_email: %d emails",
            folder.to_string(), email_ids.size);
        
        SearchPredicateInstance predicate_instance = new SearchPredicateInstance(folder, required_fields);
        
        // Convert EmailIdentifiers into associations (groupings) of EmailIdentifiers with all known
        // paths
        Gee.Collection<AssociatedEmails>? associations = null;
        try {
            associations = yield folder.account.local_search_associated_emails_async(
                email_ids, required_fields, predicate_instance.search_predicate, cancellable);
        } catch (Error err) {
            debug("Unable to search for associated emails: %s", err.message);
        }
        
        if (associations == null || associations.size == 0)
            return;
        
        process_associations(path, associations, email_ids, cancellable);
        
        Logging.debug(Logging.Flag.CONVERSATIONS, "[%s] ConversationMonitor::process_email completed: %d emails",
            folder.to_string(), email_ids.size);
    }
    
    private void process_associations(FolderPath path, Gee.Collection<AssociatedEmails> associations,
        Gee.Collection<Geary.EmailIdentifier> original_email_ids, Cancellable? cancellable) {
        Gee.HashSet<Conversation> added = new Gee.HashSet<Conversation>();
        Gee.HashMultiMap<Conversation, Email> appended = new Gee.HashMultiMap<Conversation, Email>();
        Gee.HashMultiMap<Conversation, EmailIdentifier> paths_changed = new Gee.HashMultiMap<Conversation, EmailIdentifier>();
        foreach (AssociatedEmails association in associations) {
            process_association(association, path, original_email_ids, added, appended, paths_changed,
                cancellable);
        }
        
        if (added.size > 0) {
            debug("[%s] %d conversations added from %s", to_string(), added.size, path.to_string());
            
            notify_conversations_added(added);
        }
        
        if (appended.size > 0) {
            debug("[%s] %d conversations appended with %d emails", to_string(), appended.get_keys().size,
                appended.get_values().size);
        }
        
        foreach (Conversation conversation in appended.get_keys())
            notify_conversation_appended(conversation, appended.get(conversation));
        
        if (paths_changed.size > 0) {
            debug("[%s] %d conversations paths changed for %d emails", to_string(), paths_changed.get_keys().size,
                paths_changed.get_values().size);
        }
        
        foreach (Conversation conversation in paths_changed.get_keys())
            notify_email_paths_changed(conversation, paths_changed.get(conversation));
    }
    
    private void process_association(AssociatedEmails association, FolderPath path,
        Gee.Collection<EmailIdentifier> original_email_ids, Gee.Set<Conversation> added,
        Gee.MultiMap<Conversation, Email> appended, Gee.MultiMap<Conversation, EmailIdentifier> paths_changed,
        Cancellable? cancellable) {
        // get all conversations for these emails (possible for multiple conversations to be
        // started and then coalesce as new emails come in) and see if any are known to be in this
        // folder
        bool any_in_folder = false;
        Gee.HashSet<Conversation> existing = new Gee.HashSet<Conversation>();
        foreach (EmailIdentifier associated_id in association.email_ids) {
            Conversation? conversation = all_email_id_to_conversation[associated_id];
            if (conversation != null)
                existing.add(conversation);
            
            // track if any of the messages are known to be in this folder
            if (association.known_paths[associated_id].contains(folder.path))
                any_in_folder = true;
        }
        
        // if these are out-of-folder emails, only add to conversations if any email
        // in them are associated with this folder and are not known to any other conversations
        if (!path.equal_to(folder.path) && existing.size == 0 && !any_in_folder)
            return;
        
        // Create or pick conversation for these emails
        Conversation conversation;
        switch (existing.size) {
            case 0:
                conversation = new Conversation(this);
            break;
            
            case 1:
                conversation = traverse<Conversation>(existing).first();
            break;
            
            default:
                conversation = merge_conversations(existing, paths_changed);
            break;
        }
        
        // for all ids, add known paths and associate id to conversation in the various tables,
        // since the paths and conversation may have changed
        Gee.Collection<Email> emails_appended = new Gee.ArrayList<Email>();
        foreach (EmailIdentifier associated_id in association.email_ids) {
            if (conversation.has_email(associated_id)) {
                if (conversation.add_paths(associated_id, association.known_paths[associated_id]))
                    paths_changed.set(conversation, associated_id);
            } else {
                // don't worry if add() reports paths_changed, because we've already checked if the
                // email was known, don't want to report "email-paths-changed" for a new add
                Geary.Email email = association.emails[associated_id];
                conversation.add(email, association.known_paths[associated_id], null);
                emails_appended.add(email);
            }
            
            all_email_id_to_conversation[associated_id] = conversation;
            
            // only add to primary map if identifier is part of the original set of arguments
            // and they're from this folder and not another one
            if (path.equal_to(folder.path) && original_email_ids.contains(associated_id))
                primary_email_id_to_conversation[associated_id] = conversation;
        }
        
        // if new, added, otherwise appended (if not already added)
        if (!conversations.contains(conversation)) {
            conversations.add(conversation);
            added.add(conversation);
        } else if (!added.contains(conversation) && emails_appended.size > 0) {
            foreach (Email email in emails_appended)
                appended.set(conversation, email);
        }
    }
    
    // This happens when emails with partial histories (REFERENCES) arrive out-of-order and their
    // relationship is not known until after conversations have been created ... although rare, it
    // does happen and needs to be dealt with
    private Conversation merge_conversations(Gee.Set<Conversation> conversations,
        Gee.MultiMap<Conversation, EmailIdentifier> paths_changed) {
        assert(conversations.size > 1);
        
        // Find the largest conversation and merge the others into it
        Conversation largest = traverse<Conversation>(conversations)
            .to_tree_set((ca, cb) => ca.get_count() - cb.get_count())
            .last();
        
        Gee.HashSet<EmailIdentifier> in_folder_ids = new Gee.HashSet<EmailIdentifier>();
        foreach (Conversation conversation in conversations) {
            // skip destination conversation
            if (conversation == largest)
                continue;
            
            foreach (EmailIdentifier id in conversation.get_email_ids()) {
                Email? email = conversation.get_email_by_id(id);
                if (email == null)
                    continue;
                
                Gee.Collection<FolderPath>? paths = conversation.get_known_paths_for_id(id);
                if (paths == null)
                    paths = new Gee.ArrayList<FolderPath>();
                
                bool email_paths_changed;
                largest.add(email, paths, out email_paths_changed);
                
                if (email_paths_changed)
                    paths_changed.set(largest, email.id);
                
                if (primary_email_id_to_conversation.has_key(id))
                    in_folder_ids.add(id);
            }
        }
        
        remove_emails(folder.path, in_folder_ids);
        
        return largest;
    }
    
    private void on_folder_email_appended(Gee.Collection<Geary.EmailIdentifier> appended_ids) {
        all_mail_loaded = false;
        
        operation_queue.add(new AppendOperation(this, appended_ids));
    }
    
    private void on_folder_email_inserted(Gee.Collection<Geary.EmailIdentifier> inserted_ids) {
        all_mail_loaded = false;
        
        operation_queue.add(new FillWindowOperation(this, true));
    }
    
    private void on_folder_email_removed(Gee.Collection<Geary.EmailIdentifier> removed_ids) {
        operation_queue.add(new RemoveOperation(this, removed_ids));
        operation_queue.add(new FillWindowOperation(this, false));
    }
    
    private bool is_folder_external_conversation_source(Folder folder) {
        return !folder.properties.is_local_only && !folder.properties.is_virtual;
    }
    
    private void on_account_email_locally_complete(Folder folder, Gee.Collection<EmailIdentifier> ids) {
        on_account_email_added("locally completed", folder, ids);
    }
    
    private void on_account_email_appended(Folder folder, Gee.Collection<EmailIdentifier> ids) {
        on_account_email_added("appended", folder, ids);
    }
    
    private void on_account_email_discovered(Folder folder, Gee.Collection<EmailIdentifier> ids) {
        on_account_email_added("discovered", folder, ids);
    }
    
    private void on_account_email_inserted(Folder folder, Gee.Collection<EmailIdentifier> ids) {
        on_account_email_added("inserted", folder, ids);
    }
    
    private void on_account_email_added(string why, Folder folder, Gee.Collection<EmailIdentifier> added_ids) {
        // ignore virtual/local-only folders but add new messages locally completed in this Folder
        if (is_folder_external_conversation_source(folder))
            operation_queue.add(new ExternalAppendOperation(this, why, folder, added_ids));
    }
    
    internal async void external_append_emails_async(string why, Folder folder,
        Gee.Collection<EmailIdentifier> appended_ids) {
        debug("%d out-of-folder message(s) %s in %s, fetching to add to conversations...", appended_ids.size,
            why, folder.to_string());
        
        yield process_email_ids_async(folder.path, appended_ids, cancellable_monitor);
    }
    
    private void on_account_email_removed(Folder folder, Gee.Collection<EmailIdentifier> removed_ids) {
        // ignore virtual/local-only Folders as well as removals from this Folder, which we're
        // tracking
        if (!is_folder_external_conversation_source(folder) || folder.path.equal_to(this.folder.path))
            return;
        
        operation_queue.add(new ExternalRemoveOperation(this, folder, removed_ids));
        operation_queue.add(new FillWindowOperation(this, false));
    }
    
    internal async void append_emails_async(Gee.Collection<Geary.EmailIdentifier> appended_ids) {
        debug("%d message(s) appended to %s, fetching to add to conversations...", appended_ids.size,
            folder.to_string());
        
        yield load_by_sparse_id(appended_ids, required_fields, Geary.Folder.ListFlags.NONE, null);
    }
    
    // IMPORTANT: path must be the FolderPath the removed_ids originated from
    internal void remove_emails(FolderPath path, Gee.Collection<EmailIdentifier> removed_ids) {
        debug("%d messages(s) removed from %s, trimming/removing conversations in %s...", removed_ids.size,
            path.to_string(), folder.to_string());
        
        Gee.HashSet<Conversation> removed_conversations = new Gee.HashSet<Conversation>();
        Gee.HashMultiMap<Conversation, Email> trimmed_conversations = new Gee.HashMultiMap<
            Conversation, Email>();
        Gee.HashMultiMap<Conversation, EmailIdentifier> paths_changed = new Gee.HashMultiMap<
            Conversation, EmailIdentifier>();
        
        // remove the emails from internal state, noting which conversations are trimmed or flat-out
        // removed (evaporated)
        foreach (EmailIdentifier removed_id in removed_ids) {
            // If processing removes from the primary folder, remove immediately from this mapping
            if (path.equal_to(folder.path))
                primary_email_id_to_conversation.unset(removed_id);
            
            Conversation conversation;
            if (!all_email_id_to_conversation.unset(removed_id, out conversation))
                continue;
            
            Email? email = conversation.get_email_by_id(removed_id);
            
            // Remove from conversation by *path*, which means it may not be fully removed if
            // detected in other paths
            bool fully_removed = email != null ? conversation.remove(email, path) : false;
            
            // if conversation is empty or has no messages in primary folder path, remove it
            // entirely
            if (conversation.get_count() == 0 || !conversation.any_in_folder_path(folder.path)) {
                // could have been trimmed/updated earlier in the loop
                trimmed_conversations.remove_all(conversation);
                paths_changed.remove_all(conversation);
                
                // strip Conversation from local storage and lookup tables
                conversations.remove(conversation);
                foreach (EmailIdentifier id in conversation.get_email_ids()) {
                    primary_email_id_to_conversation.unset(id);
                    all_email_id_to_conversation.unset(id);
                }
                
                removed_conversations.add(conversation);
            } else if (fully_removed && email != null) {
                // since the email was fully removed from conversation, report as trimmed
                trimmed_conversations.set(conversation, email);
            } else if (!fully_removed && email != null) {
                // the path was removed but the email remains
                paths_changed.set(conversation, email.id);
            }
        }
        
        if (trimmed_conversations.size > 0) {
            debug("[%s] Trimmed %d conversations of %d emails from %s", to_string(),
                trimmed_conversations.get_keys().size, trimmed_conversations.get_values().size,
                path.to_string());
        }
        
        foreach (Conversation conversation in trimmed_conversations.get_keys())
            notify_conversation_trimmed(conversation, trimmed_conversations.get(conversation));
        
        if (paths_changed.size > 0) {
            debug("[%s] Paths changed in %d conversations of %d emails from %s", to_string(),
                paths_changed.get_keys().size, paths_changed.get_values().size, path.to_string());
        }
        
        foreach (Conversation conversation in paths_changed.get_keys())
            notify_email_paths_changed(conversation, paths_changed.get(conversation));
        
        if (removed_conversations.size > 0) {
            debug("[%s] Removed %d conversations from %s", to_string(), removed_conversations.size,
            path.to_string());
        }
        
        foreach (Conversation conversation in removed_conversations) {
            notify_conversation_removed(conversation);
            conversation.clear_owner();
        }
    }
    
    private void on_account_email_flags_changed(Geary.Folder folder,
        Gee.Map<Geary.EmailIdentifier, Geary.EmailFlags> map) {
        foreach (Geary.EmailIdentifier id in map.keys) {
            Conversation? conversation = all_email_id_to_conversation[id];
            if (conversation == null)
                continue;
            
            Email? email = conversation.get_email_by_id(id);
            if (email == null)
                continue;
            
            email.set_flags(map.get(id));
            notify_email_flags_changed(conversation, email);
        }
    }
    
    private async Geary.EmailIdentifier? get_lowest_email_id_async(Cancellable? cancellable) {
        Geary.EmailIdentifier? earliest_id = null;
        try {
            yield folder.find_boundaries_async(primary_email_id_to_conversation.keys, out earliest_id, null,
                cancellable);
        } catch (Error e) {
            debug("Error finding earliest email identifier: %s", e.message);
        }
        
        return earliest_id;
    }
    
    private void on_folder_opened(Geary.Folder.OpenState state, int count) {
        // once remote is open, reseed with messages from the earliest ID to the latest
        if (state == Geary.Folder.OpenState.BOTH || state == Geary.Folder.OpenState.REMOTE)
            operation_queue.add(new FillWindowOperation(this, false));
    }
    
    /**
     * Attempts to load enough conversations to fill min_window_count.
     */
    internal async void fill_window_async(bool is_insert) {
        if (!is_monitoring)
            return;
        
        if (!is_insert && min_window_count <= conversations.size)
            return;
        
        if (primary_email_id_to_conversation.size >= folder.properties.email_total) {
            all_mail_loaded = true;
            
            return;
        }
        
        int initial_message_count = get_email_count();
        
        debug("fill_window_async: is_insert=%s min_window_count=%d conversations.size=%d primary_ids.size=%d folder emails=%d initial_message_count=%d",
            is_insert.to_string(), min_window_count, conversations.size, primary_email_id_to_conversation.size,
            folder.properties.email_total, initial_message_count);
        
        // only do local-load if the Folder isn't completely opened, otherwise this operation
        // will block other (more important) operations while it waits for the folder to
        // remote-open
        Folder.ListFlags flags;
        switch (folder.get_open_state()) {
            case Folder.OpenState.CLOSED:
            case Folder.OpenState.LOCAL:
            case Folder.OpenState.OPENING:
                flags = Folder.ListFlags.LOCAL_ONLY;
            break;
            
            case Folder.OpenState.BOTH:
            case Folder.OpenState.REMOTE:
                flags = Folder.ListFlags.NONE;
            break;
            
            default:
                assert_not_reached();
        }
        
        bool expected_more_email;
        
        Geary.FolderSupport.Associations? supports_associations = folder as Geary.FolderSupport.Associations;
        Geary.EmailIdentifier? low_id = yield get_lowest_email_id_async(null);
        
        if (!is_insert && supports_associations != null) {
            // easy case: just load in the Associations straight from the folder; this is (almost)
            // guaranteed to fill to the right amount every time -- the exception is when it
            // returns associations for existing conversations (i.e. the primary email id was
            // loaded earlier as an association and is now being loaded as a primary)
            yield load_associations_async(supports_associations, low_id,
                min_window_count - conversations.size, cancellable_monitor);
            
            expected_more_email = true;
        } else if (low_id != null && !is_insert) {
            // Load at least as many messages as remaining conversations.
            int num_to_load = Numeric.int_floor((min_window_count - conversations.size) * MSG_CONV_MULTIPLIER,
                MIN_FILL_MESSAGE_COUNT);
            
            yield load_by_id_async(low_id, num_to_load, Email.Field.NONE, flags, cancellable_monitor);
            
            // in this case, more email is expected to be loaded
            expected_more_email = true;
        } else {
            // No existing messages or an insert invalidated our existing list,
            // need to start from scratch.
            yield load_by_id_async(null, min_window_count * MSG_CONV_MULTIPLIER, Email.Field.NONE,
                flags, cancellable_monitor);
            
            // in this case, it's possible no new email is loaded, but that shouldn't stop a
            // reschedule
            expected_more_email = false;
        }
        
        //
        // Conditions that require a rescheduling of a FillWindowOperation:
        //
        // * Fewer conversations than the minimum window count, or
        // * Total amount of email in Folder is less than the minimum window count, and
        // * More email was expected and more was loaded.  (If no more was loaded, then reached
        //   the end of the Folder's vector -- this can happen because the email_total is not
        //   entirely reliable due to synchronization issues and local bugs)
        //
        // Note that these are not the only requirements for re-running a FillWindowOperation; the
        // preconditions at the top of this method are also baked into this decision.
        //
        
        bool reschedule =
            (conversations.size < min_window_count || folder.properties.email_total < min_window_count);
        if (reschedule && expected_more_email)
            reschedule = initial_message_count != get_email_count();
        
         // Although possible for email_total to be incorrect, be stricter for this flag
       if (folder.properties.email_total <= primary_email_id_to_conversation.size)
            all_mail_loaded = true;
        
        if (reschedule)
            operation_queue.add(new FillWindowOperation(this, false));
        
        debug("fill_window_async: loaded from %s, email_count=%d min_window_count=%d primary_ids.size=%d folder.email_total=%d conversations.size=%d rescheduled=%s",
            low_id != null ? low_id.to_string() : "(null)", get_email_count(), min_window_count, primary_email_id_to_conversation.size,
            folder.properties.email_total, conversations.size, reschedule.to_string());
    }
    
    public string to_string() {
        return "%s/%d convs/%d primary/%d total".printf(folder.to_string(), conversations.size,
            primary_email_id_to_conversation.size, all_email_id_to_conversation.size);
    }
}
