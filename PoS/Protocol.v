From mathcomp.ssreflect
Require Import ssreflect ssrbool ssrnat eqtype ssrfun seq.
From mathcomp
Require Import path.
Require Import Eqdep pred prelude idynamic ordtype pcm finmap unionmap heap coding.
Require Import Blockchain.
Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

(* Implementation of PoS protocol as a STS *)
Parameter GenesisBlock : Block.

Definition nid := nat.
Definition peers_t := seq nid.

Inductive Message :=
  | NullMsg
  | AddrMsg of nid & peers_t
  | ConnectMsg of nid
  | BlockMsg of Block
  | TxMsg of Transaction
  | InvMsg of nid & seq Hash
  | GetDataMsg of nid & Hash.

Module MsgEq.
Definition eq_msg a b :=
 match a, b with
  | NullMsg, NullMsg => true
  | NullMsg, _ => false
  | AddrMsg idA prsA, AddrMsg idB prsB => (idA == idB) && (prsA == prsB)
  | AddrMsg _ _, _ => false
  | ConnectMsg idA, ConnectMsg idB => (idA == idB)
  | ConnectMsg _, _ => false
  | BlockMsg bA, BlockMsg bB => (bA == bB)
  | BlockMsg _, _ => false
  | TxMsg tA, TxMsg tB => (tA == tB)
  | TxMsg _, _ => false
  | InvMsg pA hA, InvMsg pB hB => (pA == pB) && (hA == hB)
  | InvMsg _ _, _ => false
  | GetDataMsg pA hA, GetDataMsg pB hB => (pA == pB) && (hA == hB)
  | GetDataMsg _ _, _ => false
 end.

Ltac simple_tactic mb n n' B :=
  (case: mb=>//[|n' p'|n'|b'|t'|p' h'|p' h']; do? [by constructor 2];
   case B: (n == n'); [by case/eqP:B=><-; constructor 1|constructor 2];
   case=>E; subst n'; rewrite eqxx in B).

(* A lot of duplication in this proof; what can be done about it? *)
Lemma eq_msgP : Equality.axiom eq_msg.
Proof.
move=> ma mb. rewrite/eq_msg.
case: ma=>[|n p|n|b|t|p h|p h].
- case: mb=>//[|n' p'|n'|b'|t'|p' h'|p' h']; do? [by constructor 2]; by constructor 1.
- case: mb=>//[|n' p'|n'|b'|t'|p' h'|p' h']; do? [by constructor 2].
  case B: ((n == n') && (p == p')).
  - by case/andP: B=>/eqP<-/eqP<-; constructor 1.
  by case/Bool.andb_false_elim: B=>B; constructor 2; case; move/eqP: B.

(* TODO: unify this! *)
- by simple_tactic mb n n' B. 
- by simple_tactic mb b b' B.
- by simple_tactic mb t t' B.

- case: mb=>//[|n' p'|n'|b'|t'|p' h'|p' h']; do? [by constructor 2].
  case B: ((p == p') && (h == h')).
  - by case/andP: B=>/eqP<-/eqP<-; constructor 1.
  by case/Bool.andb_false_elim: B=>B; constructor 2; case; move/eqP: B.
(* This is literally copy-pasted from directly above; better way to do this? *)
- case: mb=>//[|n' p'|n'|b'|t'|p' h'|p' h']; do? [by constructor 2].
  case B: ((p == p') && (h == h')).
  - by case/andP: B=>/eqP<-/eqP<-; constructor 1.
  by case/Bool.andb_false_elim: B=>B; constructor 2; case; move/eqP: B.
Qed.

Canonical Msg_eqMixin := Eval hnf in EqMixin eq_msgP.
Canonical Msg_eqType := Eval hnf in EqType Message Msg_eqMixin.
End MsgEq.
Export MsgEq.

Record Packet := mkP {src: nid; dst: nid; msg: Message}.
Definition NullPacket := mkP 0 0 NullMsg.

Module PacketEq.
Definition eq_pkt a b :=
  ((src a) == (src b)) && ((dst a) == (dst b)) && ((msg a) == (msg b)).

Lemma eq_pktP : Equality.axiom eq_pkt.
Proof.
case=>sa da ma [sb] db mb; rewrite/eq_pkt/=.
case P1: (sa == sb)=>/=; last by constructor 2; case=>/eqP; rewrite P1.
case P2: (da == db)=>/=; last by constructor 2; case=> _ /eqP; rewrite P2.
case P3: (ma == mb)=>/=; last by constructor 2; case=> _ _ /eqP; rewrite P3.
by constructor 1; move/eqP: P1=><-; move/eqP: P2=><-; move/eqP: P3=><-.
Qed.

Canonical Packet_eqMixin := Eval hnf in EqMixin eq_pktP.
Canonical Packet_eqType := Eval hnf in EqType Packet Packet_eqMixin.
End PacketEq.
Export PacketEq.


Definition ToSend := seq Packet.
Definition emitZero : ToSend := [:: NullPacket].
Definition emitOne (packet : Packet) : ToSend := [:: packet].
Definition emitMany (packets : ToSend) := packets.

Definition emitOneToOne (from to : nid) (msg : Message) := [:: mkP from to msg].
Definition emitManyToOne (from to : nid) (msgs : seq Message) :=
  [seq (mkP from to msg) | msg <- msgs].


Section Node. (* Node behaviour *)

Record State :=
  Node {
    id : nid;
    peers : peers_t;
    blockTree : BlockTree;
    txPool : TxPool;
  }.

Definition Init (n : nid) : State := Node n [:: n] [:: GenesisBlock] [::].
Lemma peers_uniq_init (n : nid) : uniq [::n]. Proof. done. Qed.
  
Definition updS : State -> Message -> (State * ToSend) :=
  fun (st: State) (msg: Message) =>
    match st with
    | Node n prs bt pool =>
      match msg with
      | ConnectMsg peer => pair (Node n (undup (peer :: prs)) bt pool) emitZero

      | AddrMsg _ knownPeers =>
        let: newP := [seq x <- knownPeers | x \notin prs] in
        let: connects := [seq mkP n p (ConnectMsg n) | p <- newP] in
        pair (Node n (undup (prs ++ newP)) bt pool) (emitMany(connects))

      | BlockMsg b => pair (Node n prs (btExtend bt b) pool) emitZero

      | TxMsg tx => pair (Node n prs bt (tpExtend pool tx)) emitZero

      | InvMsg p peerHashes =>
        let: ownHashes := [seq hashB b | b <- bt] ++ [seq hashT t | t <- pool] in
        let: newH := [seq h <- peerHashes | h \notin ownHashes] in
        let: gets := [seq mkP n p (GetDataMsg n h) | h <- newH] in
        pair st (emitMany(gets))

      | GetDataMsg p h =>
        let: matchingBlocks := [seq b <- bt | (hashB b) == h] in
        let: matchingTxs := [seq t <- pool | (hashT t) == h] in
        match ohead matchingBlocks with
        | Some(b) => pair st (emitOne(mkP n p (BlockMsg b)))
        | _ =>
          match ohead matchingTxs with
          | Some (tx) => pair st (emitOne(mkP n p (TxMsg tx)))
          | _ => pair st emitZero
          end
        end

      | _ => pair st emitZero
      end
    end.

Lemma upd_id_constant : forall (s1 : State) (m : Message), 
    id s1 = id (updS s1 m).1.
Proof.
by case=> n1 p1 b1 t1 []=>//=p h; case exB: (ohead _)=>//; case exT: (ohead _).
Qed.

Lemma upd_peers_uniq :
  forall (s1 : State) (m : Message), let: s2 := (updS s1 m).1 in
    uniq (peers s1) -> uniq (peers s2).
Proof.
case=> n1 p1 b1 t1 []; do? by [].
- case=> [known | n2 known]; move=> UniqP1; by apply undup_uniq.
- simpl. move=> n2 UniqP1. case B: (n2 \in p1).
  + by apply undup_uniq.
  + rewrite cons_uniq undup_id.
    * rewrite B. by [].
    * by  [].
move=> p h. simpl. case exB: (ohead _). by [].
case exT: (ohead _); by [].
Qed.  


Inductive step (s1 s2 : State) : Prop :=
| Idle of s1 = s2
| RcvMsg (m : Message) of (s2 = (updS s1 m).1).

Lemma id_constant :
  forall (s1 s2 : State),
    step s1 s2 -> id s1 = id s2.
Proof.
move=> s1 s2.
case.
- move=> eq. rewrite eq. by [].
- move=> m Us. rewrite Us. apply upd_id_constant.
Qed.

Lemma peers_uniq :
  forall (s1 s2 : State),
    uniq (peers s1) -> step s1 s2 -> uniq (peers s2).
Proof.
move=> s1 s2 UniqP1.
case.
- move=> eq. rewrite -eq. by [].
- move=> m Us. rewrite Us. apply upd_peers_uniq. by [].
Qed.
End Node.