require "./enum"
require "./balance"

module Data
  enum UserType
    Discord
    Twitch

    def to_s(io)
      case self
      when Discord then io << "discord_id"
      when Twitch  then io << "twitch_id"
      end
    end
  end

  record TransferError, reason : String? = nil

  struct Account
    DB.mapping(
      id: Int32,
      active: Bool,
      twitch_id: Int64?,
      discord_id: Int64?,
      created_time: Time
    )

    def balance(coin : Coin)
      DATA.query_one?("SELECT balance FROM balances WHERE account_id = $1 AND coin = '#{coin}'", @id, as: BigDecimal) || BigDecimal.new(0)
    end

    def balances
      DATA.query_all?("SELECT * FROM balances WHERE account_id = $1", @id, as: Balance)
    end

    def update_balance(coin : Coin, db : DB::Connection)
      db.exec(<<-SQL, @id)
      INSERT INTO balances(coin, account_id, balance)
      SELECT
        '#{coin}',
        $1,
        (SELECT COALESCE( SUM (amount), 0) FROM transactions WHERE account_id = $1 AND coin = '#{coin}')
      ON CONFLICT(account_id, coin) DO
      UPDATE SET balance = excluded.balance;
      SQL
    end

    def self.read(user_type : UserType, id : Int64) : self
      DATA.query_one("INSERT INTO accounts(#{user_type}) VALUES ($1) ON CONFLICT (#{user_type}) DO UPDATE SET #{user_type} = accounts.#{user_type} RETURNING *", id, as: self)
    end

    def transfer(amount : BigDecimal, coin : Coin, to : Array(Account), memo : TransactionMemo, *, db : DB::Connection)
      to_string = to.map { |x| "($1, $2, $3, #{x.id})," }.join('\n')
      db.exec(<<-SQL, coin, memo, amount, @id)
      INSERT INTO transactions(coin, memo, amount, account_id)
      VALUES
        #{to_string}
        ($1, $2, -1 * $3 * #{to.size}, $4)
      SQL
    end

    def link_other_to_self(other : Account)
      discord = other.discord_id
      twitch = other.twitch_id
      kind = "discord_id" if discord
      kind = "twitch_id" if twitch
      DATA.transaction do |tx|
        begin
          db = tx.connection
          db.exec(<<-SQL, other.id, kind, discord || twitch, @id)
          UPDATE accounts SET active = false, $2 = NULL WHERE id = $1;
          UPDATE accounts SET $2 = $3 WHERE id = $4;
          INSERT INTO transactions(coin, memo, amount, account_id)
            SELECT coin, 'IMPORT_FOR_LINK', amount, $1 FROM transactions WHERE account_id = $1;
          SQL

          # TODO update_balance for all coins
          update_balance(:doge, db)
        rescue ex : PQ::PQError
          tx.rollback
          LOG.error("Unable to link Account #{@id} with #{other.id}. Exception: #{ex}")
        end
      end
    end

    def self.transfer(amount : BigDecimal, coin : Coin, from : Int64, to : Int64, platform : UserType, memo : TransactionMemo)
      multi_transfer(amount, coin, from, [to], platform, memo)
    end

    def self.multi_transfer(total : BigDecimal, coin : Coin, from : Int64, to : Array(Int64), platform : UserType, memo : TransactionMemo)
      from = read(platform, from)

      return TransferError.new("insufficient balance") unless from.balance(coin) >= total

      to = to.map { |x| read(platform, x) }

      amount = BigDecimal.new((total / to.size).round(8))
      # TODO Round mode instead
      amount = amount.round(7) if amount * to.size > total

      DATA.transaction do |tx|
        begin
          from.transfer(amount, coin, to, memo, db: tx.connection)
          to.each do |target|
            target.update_balance(coin, db: tx.connection)
          end
          from.update_balance(coin, db: tx.connection)
        rescue ex : PQ::PQError
          puts ex.inspect_with_backtrace
          LOG.warn("Rolling back transfer of type #{memo} of #{total} #{coin} from #{from} to #{to}")
          tx.rollback
          return TransferError.new
        end
      end
    end

    def self.donate(amount : BigDecimal, coin : Coin, from : Int64, platform : UserType)
      transfer(amount: amount, coin: :doge, from: from, to: 163607982473609216, platform: platform, memo: :donation)
    end
  end
end