#
# Tests for Transaction support, e.g. the ability to make multiple queries,
# across network requests, in a single transaction; commit; rollback; etc.
#

{expect} = require 'chai'
fixtures = require './fixtures'
neo4j = require '../'


## SHARED STATE

{DB, TEST_LABEL} = fixtures

[TEST_NODE_A, TEST_NODE_B, TEST_REL] = []



## HELPERS

#
# Asserts that the given object is an instance of the proper Neo4j Error
# subclass, representing the given transactional Neo4j error info.
# TODO: Consider consolidating with a similar helper in the `http` test suite.
#
expectError = (err, classification, category, title, message) ->
    expect(err).to.be.an.instanceOf neo4j[classification]   # e.g. DatabaseError
    expect(err.name).to.equal "neo4j.#{classification}"
    expect(err.message).to.equal "[#{category}.#{title}] #{message}"
    expect(err.stack).to.contain '\n'
    expect(err.stack.split('\n')[0]).to.equal "#{err.name}: #{err.message}"
    expect(err.neo4j).to.be.an 'object'
    expect(err.neo4j).to.contain
        code: "Neo.#{classification}.#{category}.#{title}"
        message: message


## TESTS

describe 'Transactions', ->

    it 'should support simple queries', (_) ->
        tx = DB.beginTransaction()

        [{foo}] = tx.cypher 'RETURN "bar" AS foo', _

        expect(foo).to.equal 'bar'

    it 'should convey pending state, and reject concurrent requests', (done) ->
        tx = DB.beginTransaction()
        expect(tx.state).to.equal 'open'

        fn = ->
            tx.cypher 'RETURN "bar" AS foo', cb
            expect(tx.state).to.equal 'pending'

        cb = (err, results) ->
            try
                expect(err).to.not.exist()
                expect(tx.state).to.equal 'open'
            catch assertionErr
                return done assertionErr
            done()

        fn()
        expect(fn).to.throw neo4j.ClientError, /concurrent requests/i

    it '(create test graph)', (_) ->
        [TEST_NODE_A, TEST_REL, TEST_NODE_B] =
            fixtures.createTestGraph module, 2, _

    it 'should isolate effects', (_) ->
        tx = DB.beginTransaction()

        # NOTE: It's important for us to create something new here, rather than
        # modify something existing. Otherwise, since we don't explicitly
        # rollback our open transaction at the end of this test, Neo4j sits and
        # waits for it to expire before returning other queries that touch the
        # existing graph -- including our last "delete test graph" step.
        # To that end, we test creating a new node here.

        {labels, properties} = fixtures.createTestNode module, _

        [{node}] = tx.cypher
            query: """
                CREATE (node:#{TEST_LABEL} {properties})
                RETURN node
            """
            params: {properties}
        , _

        expect(node).to.be.an.instanceOf neo4j.Node
        expect(node.properties).to.eql properties
        expect(node.labels).to.eql labels
        expect(node._id).to.be.a 'number'

        # Outside the transaction, we shouldn't see this newly created node:
        results = DB.cypher
            query: """
                MATCH (node:#{TEST_LABEL})
                WHERE #{(
                    # NOTE: Cypher doesn’t support directly comparing nodes and
                    # property bags, so we have to compare each property.
                    for prop of properties
                        "node.#{prop} = {properties}.#{prop}"
                ).join ' AND '}
                RETURN node
            """
            params: {properties}
        , _

        expect(results).to.be.empty()

    it 'should support committing, and reject subsequent requests', (_) ->
        tx = DB.beginTransaction()

        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'committing'
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'committing'

        expect(tx.state).to.equal 'open'
        tx.commit _
        expect(tx.state).to.equal 'committed'

        expect(-> tx.cypher 'RETURN "bar" AS foo')
            .to.throw neo4j.ClientError, /been committed/i

        # Outside of the transaction, we should see this change now:
        [{nodeA}] = DB.cypher
            query: '''
                START nodeA = node({idA})
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'committing'

    it 'should support auto-committing', (_) ->
        tx = DB.beginTransaction()

        # Rather than test auto-committing on the first query, which doesn't
        # actually create a new transaction, auto-commit on the second.

        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'auto-committing'
                SET nodeA.i = 1
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'auto-committing'
        expect(nodeA.properties.i).to.equal 1

        expect(tx.state).to.equal 'open'

        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.i = 2
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
            commit: true
        , _

        expect(nodeA.properties.test).to.equal 'auto-committing'
        expect(nodeA.properties.i).to.equal 2

        expect(tx.state).to.equal 'committed'

        expect(-> tx.cypher 'RETURN "bar" AS foo')
            .to.throw neo4j.ClientError, /been committed/i

        # Outside of the transaction, we should see this change now:
        [{nodeA}] = DB.cypher
            query: '''
                START nodeA = node({idA})
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'auto-committing'
        expect(nodeA.properties.i).to.equal 2

    it 'should support rolling back, and reject subsequent requests', (_) ->
        tx = DB.beginTransaction()

        [{nodeA}] = tx.cypher
            query: '''
                START a = node({idA})
                SET a.test = 'rolling back'
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'rolling back'

        expect(tx.state).to.equal 'open'
        tx.rollback _
        expect(tx.state).to.equal 'rolled back'

        expect(-> tx.cypher 'RETURN "bar" AS foo')
            .to.throw neo4j.ClientError, /been rolled back/i

        # Back outside this transaction now, the change should *not* be visible:
        [{nodeA}] = DB.cypher
            query: '''
                START a = node({idA})
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.not.equal 'rolling back'

    it 'should support rolling back before any commits', (_) ->
        tx = DB.beginTransaction()
        expect(tx.state).to.equal 'open'

        tx.rollback _
        expect(tx.state).to.equal 'rolled back'

    # NOTE: Skipping this test by default, because it's slow (we have to pause
    # one second; see note within) and not really a mission-critical feature.
    it.skip 'should support renewing (slow)', (_) ->
        tx = DB.beginTransaction()

        [{nodeA}] = tx.cypher
            query: '''
                START a = node({idA})
                SET a.test = 'renewing'
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'renewing'

        expect(tx.expiresAt).to.be.an.instanceOf Date
        expect(tx.expiresAt).to.be.greaterThan new Date
        expect(tx.expiresIn).to.be.a 'number'
        expect(tx.expiresIn).to.be.greaterThan 0
        expect(tx.expiresIn).to.equal tx.expiresAt - new Date

        # NOTE: We can't easily test transactions actually expiring (that would
        # take too long, and there's no way for the client to shorten the time),
        # so we can't test that renewing actually *works* / has an effect.
        # We can only test that it *appears* to work / have an effect.
        #
        # NOTE: Neo4j's expiry appears to have a granularity of one second,
        # so to be robust (local requests are frequently faster than that),
        # we pause a second first.

        oldExpiresAt = tx.expiresAt
        setTimeout _, 1000      # TODO: Provide visual feedback?

        expect(tx.state).to.equal 'open'
        tx.renew _
        expect(tx.state).to.equal 'open'

        expect(tx.expiresAt).to.be.an.instanceOf Date
        expect(tx.expiresAt).to.be.greaterThan new Date
        expect(tx.expiresAt).to.be.greaterThan oldExpiresAt
        expect(tx.expiresIn).to.be.a 'number'
        expect(tx.expiresIn).to.be.greaterThan 0
        expect(tx.expiresIn).to.equal tx.expiresAt - new Date

        # To prevent Neo4j from hanging at the end waiting for this transaction
        # to commit or expire (since it touches the existing graph, and our last
        # step is to delete the existing graph), roll this transaction back.
        tx.rollback _
        expect(tx.state).to.equal 'rolled back'

        # We also ensure that renewing didn't cause the transaction to commit.
        [{nodeA}] = DB.cypher
            query: '''
                START a = node({idA})
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.not.equal 'renewing'

    it 'should properly handle non-fatal errors', (_) ->
        tx = DB.beginTransaction()

        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'non-fatal errors'
                SET nodeA.i = 1
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'non-fatal errors'
        expect(nodeA.properties.i).to.equal 1

        # Now trigger a client error, which should *not* rollback (and thus
        # destroy) the transaction.
        # For precision, implementing this step without Streamline.
        do (cont=_) =>
            tx.cypher
                query: '''
                    START nodeA = node({idA})
                    SET nodeA.i = 2
                    RETURN {foo}
                '''
                params:
                    idA: TEST_NODE_A._id
            , (err, results) =>
                try
                    expect(err).to.exist()
                    expectError err, 'ClientError', 'Statement',
                        'ParameterMissing', 'Expected a parameter named foo'
                catch assertionErr
                    return cont assertionErr
                cont()

        expect(tx.state).to.equal 'open'

        # Because of that, the first query's effects should still be visible
        # within the transaction:
        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.i = 3
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'non-fatal errors'
        expect(nodeA.properties.i).to.equal 3

        # NOTE: But the transaction won't commit successfully apparently, both
        # manually or automatically. So we manually rollback instead.
        # TODO: Is this a bug in Neo4j? Or my understanding?
        expect(tx.state).to.equal 'open'
        tx.rollback _
        expect(tx.state).to.equal 'rolled back'

    # TODO: Similar to the note above this, is this right? Or is this either a
    # bug in Neo4j or my understanding? Should client errors never be fatal?
    it 'should properly handle fatal client errors during commit', (_) ->
        tx = DB.beginTransaction()

        # Important: don't auto-commit in the first query, because that doesn't
        # let us test that a transaction gets *returned* and *then* rolled back.
        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'fatal client errors'
                SET nodeA.i = 1
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'fatal client errors'
        expect(nodeA.properties.i).to.equal 1

        # Now trigger a client error in an auto-commit query, which *should*
        # (apparently; see comment preceding test) destroy the transaction.
        # For precision, implementing this step without Streamline.
        do (cont=_) =>
            tx.cypher
                query: '''
                    START nodeA = node({idA})
                    SET nodeA.i = 2
                    RETURN {foo}
                '''
                params:
                    idA: TEST_NODE_A._id
                commit: true
            , (err, results) =>
                try
                    expect(err).to.exist()
                    expectError err, 'ClientError', 'Statement',
                        'ParameterMissing', 'Expected a parameter named foo'
                catch assertionErr
                    return cont assertionErr
                cont()

        expect(tx.state).to.equal 'rolled back'

        expect(-> tx.cypher 'RETURN "bar" AS foo')
            .to.throw neo4j.ClientError, /been rolled back/i

        # Back outside this transaction now, the change should *not* be visible:
        [{nodeA}] = DB.cypher
            query: '''
                START a = node({idA})
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.not.equal 'fatal client errors'

    it 'should properly handle fatal database errors', (_) ->
        tx = DB.beginTransaction()

        # Important: don't auto-commit in the first query, because that doesn't
        # let us test that a transaction gets *returned* and *then* rolled back.
        [{nodeA}] = tx.cypher
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'fatal database errors'
                SET nodeA.i = 1
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.equal 'fatal database errors'
        expect(nodeA.properties.i).to.equal 1

        # The only way I know how to trigger a database error is to trigger a
        # client error, and then *separately* attempt to commit the transaction.
        # TODO: Is there any better way?
        try
            tx.cypher
                query: '''
                    START nodeA = node({idA})
                    SET nodeA.i = 2
                    RETURN {foo}
                '''
                params:
                    idA: TEST_NODE_A._id
            , _
        catch err
            expect(err).to.exist()
            expectError err, 'ClientError', 'Statement',
                'ParameterMissing', 'Expected a parameter named foo'

        # For precision, implementing this step without Streamline.
        do (cont=_) =>
            tx.commit (err) =>
                try
                    expect(err).to.exist()
                    expectError err, 'DatabaseError', 'Transaction',
                        'CouldNotCommit', 'javax.transaction.RollbackException:
                            Failed to commit, transaction rolled back'
                catch assertionErr
                    return cont assertionErr
                cont()

        expect(tx.state).to.equal 'rolled back'

        expect(-> tx.cypher 'RETURN "bar" AS foo')
            .to.throw neo4j.ClientError, /been rolled back/i

        # The change should thus *not* be visible back outside the transaction:
        [{nodeA}] = DB.cypher
            query: '''
                START a = node({idA})
                RETURN a AS nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        , _

        expect(nodeA.properties.test).to.not.equal 'fatal database errors'

    # TODO: Is there any way to trigger and test transient errors?

    it 'should properly handle errors with batching', (_) ->
        tx = DB.beginTransaction()

        results = tx.cypher [
            query: '''
                START nodeA = node({idA})
                SET nodeA.test = 'errors with batching'
            '''
            params:
                idA: TEST_NODE_A._id
        ,
            query: '''
                START nodeA = node({idA})
                SET nodeA.i = 1
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        ], _

        expect(results).to.be.an 'array'
        expect(results).to.have.length 2

        for result in results
            expect(result).to.be.an 'array'

        expect(results[0]).to.be.empty()
        expect(results[1]).to.have.length 1

        [{nodeA}] = results[1]

        expect(nodeA.properties.test).to.equal 'errors with batching'
        expect(nodeA.properties.i).to.equal 1

        expect(tx.state).to.equal 'open'

        # Now trigger a client error within another batch; this should *not*
        # rollback (and thus destroy) the transaction.
        # For precision, implementing this step without Streamline.
        do (cont=_) =>
            tx.cypher
                queries: [
                    query: '''
                        START nodeA = node({idA})
                        SET nodeA.i = 2
                        RETURN nodeA
                    '''
                    params:
                        idA: TEST_NODE_A._id
                    raw: true
                ,
                    '(syntax error)'
                ,
                    query: '''
                        START nodeA = node({idA})
                        SET nodeA.i = 3
                        RETURN nodeA
                    '''
                    params:
                        idA: TEST_NODE_A._id
                ]
            , (err, results) =>
                try
                    expect(err).to.exist()

                    # Simplified error checking, since the message is complex:
                    expect(err).to.be.an.instanceOf neo4j.ClientError
                    expect(err.neo4j).to.be.an 'object'
                    expect(err.neo4j.code).to.equal \
                        'Neo.ClientError.Statement.InvalidSyntax'

                    expect(results).to.be.an 'array'
                    expect(results).to.have.length 1

                    [result] = results

                    expect(result).to.be.an 'array'
                    expect(result).to.have.length 1

                    [{nodeA}] = result

                    # We requested `raw: true`, so `nodeA` is just properties:
                    expect(nodeA.test).to.equal 'errors with batching'
                    expect(nodeA.i).to.equal 2

                catch assertionErr
                    return cont assertionErr

                cont()

        expect(tx.state).to.equal 'open'

        # Because of that, the effects of the first query in the batch (before
        # the error) should still be visible within the transaction:
        results = tx.cypher [
            query: '''
                START nodeA = node({idA})
                RETURN nodeA
            '''
            params:
                idA: TEST_NODE_A._id
        ], _

        expect(results).to.be.an 'array'
        expect(results).to.have.length 1

        [{nodeA}] = results[0]

        expect(nodeA.properties.test).to.equal 'errors with batching'
        expect(nodeA.properties.i).to.equal 2

        # NOTE: But the transaction won't commit successfully apparently, both
        # manually or automatically. So we manually rollback instead.
        # TODO: Is this a bug in Neo4j? Or my understanding?
        expect(tx.state).to.equal 'open'
        tx.rollback _
        expect(tx.state).to.equal 'rolled back'

    it 'should support streaming (TODO)'

    it '(delete test graph)', (_) ->
        fixtures.deleteTestGraph module, _