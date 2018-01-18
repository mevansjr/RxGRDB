#if USING_SQLCIPHER
    import GRDBCipher
#else
    import GRDB
#endif
import RxSwift

final class DatabaseRegionChangeTokensObservable : ObservableType {
    typealias E = ChangeToken
    let writer: DatabaseWriter
    let startImmediately: Bool
    let scheduler: SerialDispatchQueueScheduler
    let observedRegion: (Database) throws -> DatabaseRegion
    
    /// Creates an observable that emits `.change` tokens on the database writer
    /// queue when a transaction has modified the database in a way that impacts
    /// some requests' selections.
    ///
    /// When the `startImmediately` argument is true, the observable also emits
    /// one `.databaseSubscription` and one `.subscription` token upon
    /// subscription.
    ///
    /// The `.databaseSubscription` token is emitted from the database writer
    /// queue, and the `.subscription` token is emitted from the subscription
    /// dispatch queue.
    ///
    /// It is possible for concurrent threads to commit database transactions
    /// that modify the database between the `.databaseSubscription` token and
    /// the `.subscription` token. When this happens, `.change` tokens are
    /// emitted after `.databaseSubscription`, and before `.subscription`.
    init(
        writer: DatabaseWriter,
        startImmediately: Bool,
        scheduler: SerialDispatchQueueScheduler,
        observedRegion: @escaping (Database) throws -> DatabaseRegion)
    {
        self.writer = writer
        self.startImmediately = startImmediately
        self.scheduler = scheduler
        self.observedRegion = observedRegion
    }
    
    func subscribe<O>(_ observer: O) -> Disposable where O : ObserverType, O.E == ChangeToken {
        return scheduler.schedule((writer, startImmediately, scheduler)) { (writer, startImmediately, scheduler) in
            do {
                let transactionObserver = try writer.unsafeReentrantWrite { db -> DatabaseRegionChangeObserver in
                    if startImmediately {
                        observer.onNext(ChangeToken(kind: .databaseSubscription(db), scheduler: scheduler))
                    }
                    
                    let transactionObserver = try DatabaseRegionChangeObserver(
                        observedRegion: self.observedRegion(db),
                        onChange: { observer.onNext(ChangeToken(kind: .change(writer, db), scheduler: scheduler)) })
                    db.add(transactionObserver: transactionObserver)
                    return transactionObserver
                }
                
                if startImmediately {
                    observer.onNext(ChangeToken(kind: .subscription, scheduler: scheduler))
                }
                
                return Disposables.create {
                    writer.unsafeReentrantWrite { db in
                        db.remove(transactionObserver: transactionObserver)
                    }
                }
            } catch {
                observer.onError(error)
                return Disposables.create()
            }
        }
    }
}
