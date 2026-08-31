# Phlea Market

A Project Zomboid (B42) mod that adds a vending machine stocking itself from other
players' pockets. Hand it something, name a price, and it holds the item in escrow until
somebody buys it or the clock runs out.

> **Requires:** [PhunMart 2](https://github.com/PhunZoider/PhunMart). This mod does nothing on its own.
> **Build:** Project Zomboid B42 (singleplayer or multiplayer)

---

## Status

**In development.** The machine is disabled in `defaults/shops.lua` until its tile pack
exists, so nothing appears in the world yet. See [Building it](#building-it) below.

## How it works

A seller opens any Phlea Market, switches to **Sell**, picks an item, chooses how long to
list it for and names a unit price. The item leaves their inventory that instant and is held
on the server. It shows up in the **Buy** view of every Phlea Market in the world until it
sells out or expires.

- **Sales** credit the seller, minus commission. Proceeds that would breach the wallet cap
  are held rather than lost.
- **Expiry** drops whatever is left into the seller's **Returns** queue, collectable from any
  machine, with a one-click relist at the remembered price.
- **Ownership follows the account, not the character.** Dying does not forfeit an escrowed
  axe: it was already out of the world when the character died.

Items keep their condition. A 12% axe sells as a 12% axe and comes back as one, which is
the difference between a market and a repair bench. Magazines, attachments and bag contents
are returned to the seller when the item is listed rather than travelling with it, and the
confirmation says so before anything moves.

Stacks are one listing with a unit price rather than fifty listings, restricted to items where
every one is interchangeable. The Buy grid groups by item type and orders listings cheapest
first, then oldest first, so two sellers asking the same price are served in the order they
listed.

## Building it

Requires a PhunMart 2 checkout beside this one, since the two are developed together:

```
d:\pz-dev\code\PhunMart2
d:\pz-dev\code\PhleaMarket
```

```
deploy.cmd
```

Copies to `%USERPROFILE%\Zomboid\mods\PhleaMarket`, a `PhleaMarketTest` variant carrying the
dev mod id so both can sit in one install, and both Workshop staging folders. PhunMart 2 has
to be deployed and enabled alongside it.

```
Tests\lua\run.cmd
```

Runs the offline suites under LuaJIT. See [Tests/lua/README.md](Tests/lua/README.md).

## Settings

Twenty sandbox options on their own **Phlea Market** page: listing durations and their fee
multipliers, listing fee and commission (each a percentage or a flat amount), per-account
listing limits, price floor and ceiling, how long uncollected returns survive, and the size of
the admin ledger.

Fees are worked out when a listing goes up and stored on it, so a seller sees their exact
take-home before confirming and a mid-listing settings change cannot retroactively tax
something already on the shelf.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
