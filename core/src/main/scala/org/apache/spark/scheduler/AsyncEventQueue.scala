/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.spark.scheduler

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.{AtomicBoolean, AtomicLong}

import org.apache.spark.{SparkConf, SparkContext, SparkException}
import org.apache.spark.internal.Logging
import org.apache.spark.internal.config._
import org.apache.spark.util.Utils

/**
 * An asynchronous queue for events. All events posted to this queue will be delivered to the child
 * listeners in a separate thread.
 *
 * Delivery will only begin when the `start()` method is called. The `stop()` method should be
 * called when no more events need to be delivered.
 */
private class AsyncEventQueue(val name: String, conf: SparkConf)
  extends SparkListenerBus
  with Logging {

  import AsyncEventQueue._

  private def validateAndGetQueueSize(): Int = {
    val queueSize = conf.get(LISTENER_BUS_EVENT_QUEUE_SIZE)
    if (queueSize <= 0) {
      throw new SparkException(s"${LISTENER_BUS_EVENT_QUEUE_SIZE.key} must be > 0!")
    }
    queueSize
  }

  // Cap the capacity of the queue so we get an explicit error (rather than an OOM exception) if
  // it's perpetually being added to more quickly than it's being drained.
  private val EVENT_QUEUE_CAPACITY = validateAndGetQueueSize()
  private val eventQueue = new LinkedBlockingQueue[SparkListenerEvent](EVENT_QUEUE_CAPACITY)

  // Keep the event count separately, so that waitUntilEmpty() can be implemented properly;
  // this allows that method to return only when the events in the queue have been fully
  // processed (instead of just dequeued).
  private val eventCount = new AtomicLong()

  /** A counter for dropped events. It will be reset every time we log it. */
  private val droppedEventsCounter = new AtomicLong(0L)

  /** When `droppedEventsCounter` was logged last time in milliseconds. */
  @volatile private var lastReportTimestamp = 0L

  private val logDroppedEvent = new AtomicBoolean(false)

  private var sc: SparkContext = null

  private val started = new AtomicBoolean(false)
  private val stopped = new AtomicBoolean(false)

  private val dispatchThread = new Thread(s"spark-listener-group-$name") {
    setDaemon(true)
    override def run(): Unit = Utils.tryOrStopSparkContext(sc) {
      dispatch()
    }
  }

  private def dispatch(): Unit = LiveListenerBus.withinListenerThread.withValue(true) {
    try {
      var next: SparkListenerEvent = eventQueue.take()
      while (next != POISON_PILL) {
        super.postToAll(next)
        eventCount.decrementAndGet()
        next = eventQueue.take()
      }
      eventCount.decrementAndGet()
    } catch {
      case ie: InterruptedException =>
        logInfo(s"Stopping listener queue $name.", ie)
    }
  }

  /**
   * Start an asynchronous thread to dispatch events to the underlying listeners.
   *
   * @param sc Used to stop the SparkContext in case the async dispatcher fails.
   */
  private[scheduler] def start(sc: SparkContext): Unit = {
    if (started.compareAndSet(false, true)) {
      this.sc = sc
      dispatchThread.start()
    } else {
      throw new IllegalStateException(s"$name already started!")
    }
  }

  /**
   * Stop the listener bus. It will wait until the queued events have been processed, but new
   * events will be dropped.
   */
  private[scheduler] def stop(): Unit = {
    if (!started.get()) {
      throw new IllegalStateException(s"Attempted to stop $name that has not yet started!")
    }
    if (stopped.compareAndSet(false, true)) {
      eventQueue.put(POISON_PILL)
      eventCount.incrementAndGet()
    }
    dispatchThread.join()
  }

  def post(event: SparkListenerEvent): Unit = {
    if (stopped.get()) {
      return
    }

    eventCount.incrementAndGet()
    if (eventQueue.offer(event)) {
      return
    }

    eventCount.decrementAndGet()
    droppedEventsCounter.incrementAndGet()
    if (logDroppedEvent.compareAndSet(false, true)) {
      // Only log the following message once to avoid duplicated annoying logs.
      logError(s"Dropping event from queue $name. " +
        "This likely means one of the listeners is too slow and cannot keep up with " +
        "the rate at which tasks are being started by the scheduler.")
    }
    logTrace(s"Dropping event $event")

    val droppedCount = droppedEventsCounter.get
    if (droppedCount > 0) {
      // Don't log too frequently
      if (System.currentTimeMillis() - lastReportTimestamp >= 60 * 1000) {
        // There may be multiple threads trying to decrease droppedEventsCounter.
        // Use "compareAndSet" to make sure only one thread can win.
        // And if another thread is increasing droppedEventsCounter, "compareAndSet" will fail and
        // then that thread will update it.
        if (droppedEventsCounter.compareAndSet(droppedCount, 0)) {
          val prevLastReportTimestamp = lastReportTimestamp
          lastReportTimestamp = System.currentTimeMillis()
          val previous = new java.util.Date(prevLastReportTimestamp)
          logWarning(s"Dropped $droppedCount events from $name since $previous.")
        }
      }
    }
  }

  /**
   * For testing only. Wait until there are no more events in the queue.
   *
   * @return true if the queue is empty.
   */
  def waitUntilEmpty(deadline: Long): Boolean = {
    while (eventCount.get() != 0) {
      if (System.currentTimeMillis > deadline) {
        return false
      }
      Thread.sleep(10)
    }
    true
  }

}

private object AsyncEventQueue {

  val POISON_PILL = new SparkListenerEvent() { }

}
